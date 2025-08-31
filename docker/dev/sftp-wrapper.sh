#!/usr/bin/env bash
# Wrapper SFTP pour supporter indirectement `mkdir -p` en batch.
# - Précrée les répertoires via `ssh` (avec -p côté shell distant)
# - Nettoie le batch pour enlever les lignes `mkdir -p`
set -euo pipefail

real_sftp="/usr/bin/sftp"

batch_file=""
host=""
args=()

while (( "$#" )); do
  case "$1" in
    -b)
      batch_file="$2"; shift 2; args+=("-b" "$batch_file");;
    --)
      shift; while (( "$#" )); do args+=("$1"); shift; done; break;;
    -*)
      args+=("$1"); shift;;
    *)
      host="$1"; shift;;
  esac
done

if [ -z "${batch_file:-}" ] || [ -z "${host:-}" ]; then
  exec "$real_sftp" "${args[@]}" "$host"
fi

# Extraire REMOTE_PATH depuis la première ligne `cd <path>` du batch
remote_base=""
remote_base=$(awk 'tolower($1)=="cd" {print $2; exit}' "$batch_file" || true)
if [ -z "$remote_base" ]; then
  # Pas de cd: utiliser racine distante
  remote_base="."
fi

# Collecte des répertoires à créer à partir des lignes `put local remote`
mapfile -t dirs < <(awk 'tolower($1)=="put" {print $3}' "$batch_file" | xargs -I{} dirname {} | sort -u | sed '/^\.$/d')

if [ ${#dirs[@]} -gt 0 ]; then
  for d in "${dirs[@]}"; do
    # Construction du chemin absolu si cd utilisé
    if [ "$remote_base" != "." ]; then
      target="$remote_base/$d"
    else
      target="$d"
    fi
    ssh "$host" "mkdir -p -- \"$target\"" || true
  done
fi

# Créer un batch temporaire sans `mkdir -p`
tmp_batch=$(mktemp)
awk 'BEGIN{IGNORECASE=1} !($1=="mkdir" && $2=="-p") {print $0}' "$batch_file" > "$tmp_batch"

exec "$real_sftp" -b "$tmp_batch" "$host"
