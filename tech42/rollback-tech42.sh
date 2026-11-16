#!/usr/bin/env bash
# Desfaz SOMENTE o que esta instalacao criou (DeskcommCRM + Supabase proprio).
# Nao toca Fiado Pro nem outros projetos.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
NET_NAME="deskcommcrm_supabase"

log() { printf '[tech42-rollback] %s\n' "$*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
  log "Parando stack CRM"
  (cd "$PROJECT_DIR" && docker compose --env-file .env \
    -f docker-compose.prod.yml \
    -f docker-compose.single-server.yml \
    -f docker-compose.tech42.yml \
    down --remove-orphans) || true
fi

if [[ -f "$PROJECT_DIR/.runtime/supabase/.env" ]]; then
  log "Parando stack Supabase Deskcomm"
  (cd "$PROJECT_DIR/.runtime/supabase" && docker compose --env-file .env \
    -f docker-compose.yml \
    -f docker-compose.deskcomm.yml \
    -f docker-compose.tech42.yml \
    down --remove-orphans) || true
fi

if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  log "Removendo rede $NET_NAME"
  docker network rm "$NET_NAME" || true
fi

log "Rollback de containers/rede concluido."
log "Pasta $PROJECT_DIR mantida (apague manualmente se quiser). Volumes Supabase em .runtime/supabase/volumes."
