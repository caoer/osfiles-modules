#!/usr/bin/env bash
# Re-apply the local patches carried on vendored yazi plugins.
#
# `ya pkg` hashes each plugin against package.toml and refuses to upgrade one
# that has been edited, so a patched plugin can only move with --discard, which
# restores pristine upstream first. This puts the patches back:
#
#     ya pkg upgrade --discard wylie102/duckdb
#     config/yazi/plugins/patches/apply.sh
#     git diff
#
# Patches apply in filename order, and each was generated against the state its
# predecessor leaves behind, so `git apply` lands them with no fuzz. Idempotent:
# a patch already present is reported, not applied twice.
#
# A FAILED patch means upstream changed the lines it rewrites. Re-derive it from
# the new upstream rather than forcing it — see LOCAL-PATCHES.md.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugins=$(dirname -- "$here")

mode=apply
case "${1-}" in
	--check) mode=check ;;
	"") ;;
	*)
		echo "usage: ${0##*/} [--check]" >&2
		exit 2
		;;
esac

rc=0
for dir in "$here"/*/; do
	plugin=$(basename -- "$dir")
	target="$plugins/$plugin"

	if [ ! -d "$target" ]; then
		echo "MISSING  $plugin — patched plugin is not installed" >&2
		rc=1
		continue
	fi

	# `ya pkg` deploys plugin files read-only (0444), so a freshly discarded
	# plugin has nothing `git apply` can write to. Git records only the execute
	# bit, so putting 0444 back afterwards would be invisible to the repo and to
	# the next checkout — leave them writable instead.
	[ "$mode" = apply ] && chmod -R u+w "$target"

	for patch in "$dir"*.diff; do
		[ -e "$patch" ] || continue
		name="$plugin/$(basename -- "$patch")"

		if git -C "$target" apply --check -p1 "$patch" 2>/dev/null; then
			if [ "$mode" = check ]; then
				echo "WOULD    $name"
			else
				git -C "$target" apply -p1 "$patch"
				echo "APPLIED  $name"
			fi
		elif git -C "$target" apply --check -p1 --reverse "$patch" 2>/dev/null; then
			echo "PRESENT  $name"
		else
			echo "FAILED   $name — upstream moved under it, re-derive" >&2
			rc=1
		fi
	done
done

exit $rc
