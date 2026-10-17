# codex-update — the user-level codex CLI, kept current outside nix.
#
# Version: the pin file ($root/pin, one version) when present, else npm's
# `latest` dist-tag. A version not yet on disk is fetched as upstream's platform
# tarball, checked against the registry's sha512 integrity, unpacked whole
# (package/vendor/<target>, the tree packages/codex.nix installs) to
# $root/<version>/, and $link is pointed at <version>/bin/codex by one rename.
# The version it replaced stays on disk (recorded in $root/previous); any other
# version dir is removed unless a running process executes from it.
# A run with nothing new changes nothing.
#
# Roll back: echo <version> > ~/.local/share/codex/pin, then
# systemctl --user start codex-update. Remove the pin to follow latest again.
#
# platform and target are set above this text by packages/codex-update.nix.

registry="https://registry.npmjs.org/@openai/codex"
root="$HOME/.local/share/codex"
link="$HOME/.local/bin/codex"
version_re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

die() {
  echo "codex-update: $*" >&2
  exit 1
}

mkdir -p "$root" "$(dirname "$link")"
root=$(realpath "$root")

# A real file at $link is someone else's install: never overwrite it.
if [ -e "$link" ] && [ ! -L "$link" ]; then
  die "$link is not a symlink; move it away to let this unit manage codex"
fi

# complete <dir> <version>: an unpacked release of exactly that version.
complete() {
  [ -x "$1/bin/codex" ] && [ -f "$1/codex-package.json" ] &&
    [ "$(jq -r .version "$1/codex-package.json")" = "$2" ]
}

manifest=""
if [ -s "$root/pin" ]; then
  want=$(tr -d '[:space:]' <"$root/pin")
  from="pin"
else
  from="latest"
  manifest=$(curl -fsSL "$registry/latest") || die "cannot read the registry's latest"
  want=$(jq -r .version <<<"$manifest")
fi
[[ $want =~ $version_re ]] || die "not a version: '$want' ($from)"

dir="$root/$want"

if ! complete "$dir" "$want"; then
  if [ -z "$manifest" ]; then
    manifest=$(curl -fsSL "$registry/$want") || die "codex $want ($from) not found in the registry"
  fi
  spec=$(jq -r --arg p "@openai/codex-$platform" '.optionalDependencies[$p] // empty' <<<"$manifest")
  pver=${spec#npm:@openai/codex@}
  [ -n "$spec" ] && [ "$pver" != "$spec" ] || die "codex $want names no $platform package ('$spec')"
  pmanifest=$(curl -fsSL "$registry/$pver") || die "cannot read the manifest of $pver"
  tarball=$(jq -r .dist.tarball <<<"$pmanifest")
  integrity=$(jq -r .dist.integrity <<<"$pmanifest")
  [[ $integrity == sha512-* ]] || die "$pver carries no sha512 integrity ('$integrity')"

  tmp=$(mktemp -d "$root/.incoming.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$tarball" -o "$tmp/pkg.tgz" || die "download failed: $tarball"
  got="sha512-$(openssl dgst -sha512 -binary "$tmp/pkg.tgz" | base64 -w0)"
  [ "$got" = "$integrity" ] || die "integrity mismatch for $tarball: registry $integrity, got $got"

  tar -xzf "$tmp/pkg.tgz" -C "$tmp" "package/vendor/$target"
  new="$tmp/package/vendor/$target"
  complete "$new" "$want" || die "$pver unpacked no complete codex $want tree"
  [ "$("$new/bin/codex" --version)" = "codex-cli $want" ] || die "$pver's bin/codex does not report codex-cli $want"

  # A dir at $dir that is not a complete $want is debris from an interrupted
  # hand copy; it leaves with $tmp.
  if [ -e "$dir" ]; then mv -T "$dir" "$tmp/debris"; fi
  mv -T "$new" "$dir"
  echo "codex-update: installed codex $want ($from) at $dir, sha512 checked"
fi

cur=$(readlink -e "$link" || true)
if [ "$cur" != "$dir/bin/codex" ]; then
  ln -sfn "$dir/bin/codex" "$link.codex-update"
  mv -fT "$link.codex-update" "$link"
  case "$cur" in
    "$root"/*/bin/codex)
      prev=${cur#"$root"/}
      prev=${prev%%/*}
      echo "$prev" >"$root/previous"
      ;;
  esac
  echo "codex-update: $link -> codex $want ($from), was ${cur:-absent}"
else
  echo "codex-update: codex $want ($from) is current"
fi

# Keep the current, the previous and the pinned version; drop the rest unless a
# running process still executes from one (a seat on an older codex finds its
# rg, bwrap and helpers next to its own binary).
keep=" $want $(cat "$root/previous" 2>/dev/null || true) $(tr -d '[:space:]' <"$root/pin" 2>/dev/null || true) "
for d in "$root"/*/; do
  d=${d%/}
  v=${d##*/}
  [[ $v =~ $version_re ]] || continue
  [[ $keep == *" $v "* ]] && continue
  busy=""
  for exe in /proc/[0-9]*/exe; do
    t=$(readlink "$exe" 2>/dev/null) || continue
    case "$t" in "$d"/*)
      busy=${exe#/proc/}
      busy=${busy%/exe}
      break
      ;;
    esac
  done
  if [ -n "$busy" ]; then
    echo "codex-update: keeping codex $v, pid $busy runs from it"
  else
    rm -rf "$d"
    echo "codex-update: removed codex $v"
  fi
done
