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
      batch_file="$2"; shift 2;;
    -o|-P|-i|-F|-c|-S|-J|-s)
      args+=("$1" "$2"); shift 2;;
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

# Collecte des répertoires à créer à partir des lignes `put [-opts] local remote`
# On prend le dernier champ comme cible distante (remote)
mapfile -t dirs < <(awk 'tolower($1)=="put" {print $NF}' "$batch_file" | xargs -I{} dirname {} | sort -u | sed '/^\.$/d')

if [ ${#dirs[@]} -gt 0 ]; then
  for d in "${dirs[@]}"; do
    # Construction du chemin absolu si cd utilisé
    if [ "$remote_base" != "." ]; then
      target="$remote_base/$d"
    else
      target="$d"
    fi
    ssh -q -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$host" "mkdir -p -- \"$target\"" || true
  done
fi

# Créer un batch temporaire sans `mkdir -p`
tmp_batch=$(mktemp)
awk 'BEGIN{IGNORECASE=1} !($1=="mkdir" && $2=="-p") {print $0}' "$batch_file" > "$tmp_batch"

# Filtrer les options -b existantes des args pour éviter les doublons
filtered_args=()
skip_next=0
for (( i=0; i<${#args[@]}; i++ )); do
  if [ $skip_next -eq 1 ]; then
    skip_next=0
    continue
  fi
  if [ "${args[$i]}" = "-b" ]; then
    skip_next=1
    continue
  fi
  filtered_args+=("${args[$i]}")
done

exec "$real_sftp" "${filtered_args[@]}" -b "$tmp_batch" "$host"
