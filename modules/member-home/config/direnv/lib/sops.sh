# use_sops — decrypt SOPS namespaces into env vars via direnv
#
# Layout: secrets are split by namespace into secrets/<namespace>.yaml,
# keys flat at the file root. The first dot-segment of the namespace path
# selects the file; remaining segments index into it.
#
# Usage:
#   use_sops <dot.path> [--prefix PREFIX] [--file PATH] [--upper]
#
# Examples:
#   use_sops global --upper
#     → reads secrets/global.yaml (root), exports each key uppercased
#       e.g. SUPERZ_CHAT_ID=xxx SUPERZ_TOPIC_ID=yyy
#
#   use_sops cloudflare.sui_0xdao --prefix CLOUDFLARE_ --upper
#     → reads secrets/cloudflare.yaml, extracts ["sui_0xdao"]
#       exports CLOUDFLARE_API_TOKEN=xxx CLOUDFLARE_ACCOUNT_ID=yyy
#
#   use_sops global.superz_chat_id
#     → reads secrets/global.yaml, extracts ["superz_chat_id"] (scalar leaf)
#       exports superz_chat_id=xxx
#
#   use_sops anything --file path/to/file.yaml
#     → explicit file; the FULL dot.path indexes into it (no file-from-segment)
#
# Requires: sops, jq, SOPS_AGE_KEY_FILE in env
#
# Migration note: the old monolithic secrets.yaml layout indexed the whole
# path against one file. The split layout maps secrets.yaml["a"]["b"] →
# secrets/a.yaml ["b"], so callers keep the same dot.path.

use_sops() {
  local ns="${1:?use_sops: namespace required (e.g. cloudflare.sui_0xdao)}"
  shift

  local prefix="" secrets_file="" upper=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix) prefix="$2"; shift 2 ;;
      --file)   secrets_file="$2"; shift 2 ;;
      --upper)  upper=true; shift ;;
      *) log_error "use_sops: unknown arg '$1'"; return 1 ;;
    esac
  done

  if ! has sops; then
    log_error "use_sops: sops not found in PATH"
    return 1
  fi

  if ! has jq; then
    log_error "use_sops: jq not found in PATH"
    return 1
  fi

  # Resolve file + the extract path within it.
  #   --file given      → use it, full ns is the extract path
  #   no --file         → first segment is secrets/<seg>.yaml, rest is the path
  local extract_ns
  if [[ -n "$secrets_file" ]]; then
    extract_ns="$ns"
  else
    local seg1="${ns%%.*}"
    secrets_file="$(find_up "secrets/${seg1}.yaml")"
    if [[ -z "$secrets_file" ]]; then
      log_error "use_sops: no secrets/${seg1}.yaml found"
      return 1
    fi
    if [[ "$ns" == *.* ]]; then
      extract_ns="${ns#*.}"   # drop the file segment
    else
      extract_ns=""           # whole-file root
    fi
  fi

  # Decrypt: indexed extract, or the whole file (minus sops metadata).
  local json
  if [[ -n "$extract_ns" ]]; then
    # "a.b.c" → '["a"]["b"]["c"]'
    local extract_path
    extract_path=$(printf '%s' "$extract_ns" | awk -F. '{for(i=1;i<=NF;i++) printf "[\"" $i "\"]"}')
    json=$(sops decrypt --output-type json --extract "$extract_path" "$secrets_file" 2>&1)
  else
    json=$(sops decrypt --output-type json "$secrets_file" 2>&1)
  fi
  if [[ $? -ne 0 ]]; then
    log_error "use_sops: failed to decrypt '$ns' from $secrets_file"
    log_error "$json"
    return 1
  fi
  # Drop sops metadata when reading a whole file root.
  if [[ -z "$extract_ns" ]]; then
    json=$(printf '%s' "$json" | jq 'del(.sops)')
  fi

  local val_type
  val_type=$(printf '%s' "$json" | jq -r 'type')

  # Scalar leaf — export as last segment of the path
  if [[ "$val_type" != "object" ]]; then
    local key="${ns##*.}"
    $upper && key=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
    export "${prefix}${key}=$(printf '%s' "$json" | jq -r '.')"
    log_status "sops: ${prefix}${key}"
    return 0
  fi

  # Object — export each key
  local count=0
  local line key value
  while IFS=$'\t' read -r key value; do
    [[ -z "$key" ]] && continue
    $upper && key=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
    export "${prefix}${key}=${value}"
    count=$((count + 1))
  done < <(printf '%s' "$json" | jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv')

  log_status "sops: ${ns} (${count} keys)"
}
