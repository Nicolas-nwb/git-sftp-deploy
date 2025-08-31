#!/usr/bin/env bash
# Génère une paire de clés ed25519 pour les tests si absente.
set -euo pipefail

root_dir="$(cd "$(dirname "$0")"/.. && pwd)"
keys_dir="$root_dir/docker/keys"

mkdir -p "$keys_dir"

if [ -f "$keys_dir/id_ed25519" ]; then
  echo "[keys] Clés déjà présentes: $keys_dir/id_ed25519"
  exit 0
fi

echo "[keys] Génération d'une paire de clés ed25519..."
ssh-keygen -t ed25519 -N "" -f "$keys_dir/id_ed25519" -C "git-sftp-deploy@test"

chmod 600 "$keys_dir/id_ed25519"
chmod 644 "$keys_dir/id_ed25519.pub"

echo "[keys] OK: $keys_dir/id_ed25519(.pub)"
