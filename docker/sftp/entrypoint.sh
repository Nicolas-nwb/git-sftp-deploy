#!/usr/bin/env bash
set -euo pipefail

# Entrypoint SSHD: génère les clés hôte si absent et démarre sshd

echo "[sftp] Bootstrapping sshd..."

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi

# Vérif des permissions clés autorisées
if [ -f /home/deploy/.ssh/authorized_keys ]; then
  chown deploy:deploy /home/deploy/.ssh/authorized_keys || true
  chmod 600 /home/deploy/.ssh/authorized_keys || true
fi

chown -R deploy:deploy /var/www/html

echo "[sftp] Starting sshd on :22"
exec /usr/sbin/sshd -D -e
