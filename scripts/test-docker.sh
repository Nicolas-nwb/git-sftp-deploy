#!/usr/bin/env bash
# Orchestration: build, init, start, test déploiement
set -euo pipefail

echo "[orchestrator] Préparation des clés... (intégrées aux images)"

echo "[orchestrator] Construction des images..."
docker compose build --pull

echo "[orchestrator] Démarrage des services (sftp + dev)..."
docker compose up -d sftp dev

echo "[orchestrator] Attente SFTP prêt (tcp 172.28.0.10:22)..."
docker compose exec -T dev bash -lc '
for i in {1..60}; do
  if (echo > /dev/tcp/172.28.0.10/22) >/dev/null 2>&1; then
    echo "ready"; exit 0;
  fi
  sleep 1
done
echo "timeout" >&2; exit 1
'
echo "[orchestrator] SFTP prêt."

echo "[orchestrator] Lancement des tests de base dans dev..."
docker compose exec -T dev bash -lc "chmod +x scripts/inside-dev/run-tests.sh && scripts/inside-dev/run-tests.sh"

echo "[orchestrator] Lancement des tests edge case dans dev..."
docker compose exec -T dev bash -lc "chmod +x scripts/inside-dev/test-edge-cases.sh && scripts/inside-dev/test-edge-cases.sh"

echo "[orchestrator] Tous les tests terminés. Contenu distant dans ./tests/remote-www"
