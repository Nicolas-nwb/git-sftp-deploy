#!/usr/bin/env bash
# Orchestration: build, init, start, test déploiement
set -euo pipefail

echo "[orchestrator] Préparation des clés..."
"$(dirname "$0")"/setup-keys.sh

echo "[orchestrator] Construction des images..."
docker compose build --pull

echo "[orchestrator] Démarrage des services (sftp + dev)..."
docker compose up -d sftp dev

echo "[orchestrator] Attente SFTP prêt (port 2222 côté host)..."
docker compose exec -T dev bash -lc '
for i in {1..60}; do
  if (echo > /dev/tcp/host.docker.internal/2222) >/dev/null 2>&1; then
    echo "ready"; exit 0;
  fi
  sleep 1
done
echo "timeout" >&2; exit 1
'
echo "[orchestrator] SFTP prêt."

echo "[orchestrator] Lancement du test dans dev..."
docker compose exec -T dev bash -lc "chmod +x scripts/inside-dev/run-tests.sh && scripts/inside-dev/run-tests.sh"

echo "[orchestrator] Test terminé. Contenu distant dans ./tests/remote-www"
