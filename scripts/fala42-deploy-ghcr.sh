#!/usr/bin/env bash
# Deploy Fala42 puxando imagens do GHCR (app + worker).
#
# Este script NÃO faz parte do compose versionado neste repositório. O compose
# de produção continua em:
#   /srv/projetos/clientes/fala42/docker-compose.tech42.yml
# O PR que adiciona o workflow de build NÃO altera esse arquivo — só publica
# imagens e documenta como aplicá-las manualmente na VPS.
#
# Uso típico (usuário jorge, sem sudo):
#   bash scripts/fala42-deploy-ghcr.sh --tag prod
#   bash scripts/fala42-deploy-ghcr.sh --tag abc1234 --dry-run
#
set -euo pipefail

REGISTRY_OWNER="${FALA42_REGISTRY_OWNER:-jorgecavalcant}"
APP_IMAGE_DEFAULT="ghcr.io/${REGISTRY_OWNER}/fala42-app"
WORKER_IMAGE_DEFAULT="ghcr.io/${REGISTRY_OWNER}/fala42-worker"
COMPOSE_FILE="${FALA42_COMPOSE_FILE:-/srv/projetos/clientes/fala42/docker-compose.tech42.yml}"
COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
BACKUP_DIR="${FALA42_BACKUP_DIR:-${COMPOSE_DIR}/.deploy-backups}"
SERVICES=(app worker)
TAG=""
DRY_RUN=0
HEALTH_WAIT_SECS="${FALA42_HEALTH_WAIT_SECS:-120}"

usage() {
  cat <<'EOF'
fala42-deploy-ghcr.sh — atualiza app e worker com imagens do GHCR (Fala42)

IMPORTANTE: este repositório/PR não muda o compose de produção na VPS.
O arquivo real é /srv/projetos/clientes/fala42/docker-compose.tech42.yml
(edite-o manualmente ou use as variáveis APP_IMAGE/WORKER_IMAGE se já existirem).

Opções:
  --tag <tag>       Tag no GHCR (ex.: prod ou SHA curto). Obrigatório exceto em --help.
  --dry-run         Mostra o que faria, sem docker pull/up nem alterar arquivos.
  --compose <path>  Compose de produção (default: FALA42_COMPOSE_FILE ou caminho acima).
  -h, --help        Esta ajuda.

Variáveis de ambiente:
  FALA42_COMPOSE_FILE      Caminho do compose de produção.
  FALA42_REGISTRY_OWNER    Dono no GHCR (default: jorgecavalcant).
  FALA42_BACKUP_DIR        Pasta para backup de referências de imagem.
  FALA42_HEALTH_WAIT_SECS  Tempo máximo aguardando health (default: 120).

Exemplos:
  bash scripts/fala42-deploy-ghcr.sh --help
  bash scripts/fala42-deploy-ghcr.sh --tag prod --dry-run
  bash scripts/fala42-deploy-ghcr.sh --tag prod
EOF
}

log() { printf '[fala42-deploy] %s\n' "$*"; }
die() { log "ERRO: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "comando não encontrado: $1"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $*"
  else
    log "exec: $*"
    "$@"
  fi
}

patch_service_image() {
  local svc="$1"
  local img="$2"
  local src="$3"
  local dst="$4"
  awk -v svc="$svc" -v img="$img" '
    $0 ~ "^[[:space:]]*" svc ":" { in_svc=1 }
    in_svc && /^[[:space:]]*[a-zA-Z0-9_.-]+:/ && $0 !~ "^[[:space:]]*" svc ":" { in_svc=0 }
    in_svc && /^[[:space:]]*image:/ { sub(/image:.*/, "image: " img); in_svc=0 }
    { print }
  ' "$src" >"$dst"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --tag)
      shift
      TAG="${1:-}"
      [ -n "$TAG" ] || die "--tag exige um valor"
      ;;
    --compose)
      shift
      COMPOSE_FILE="${1:-}"
      [ -n "$COMPOSE_FILE" ] || die "--compose exige um caminho"
      COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
      ;;
    *)
      die "opção desconhecida: $1 (use --help)"
      ;;
  esac
  shift
done

if [ -z "${TAG:-}" ]; then
  usage >&2
  die "informe --tag (ex.: prod)"
fi

APP_IMAGE="${APP_IMAGE_DEFAULT}:${TAG}"
WORKER_IMAGE="${WORKER_IMAGE_DEFAULT}:${TAG}"

if [ "$DRY_RUN" -eq 0 ]; then
  require_cmd docker
  [ -f "$COMPOSE_FILE" ] || die "compose não encontrado: $COMPOSE_FILE"
else
  BACKUP_DIR="${TMPDIR:-/tmp}/fala42-deploy-dry-run"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_MANIFEST="${BACKUP_DIR}/manifest-${TS}.env"
COMPOSE_BACKUP=""

mkdir -p "$BACKUP_DIR"

snapshot_compose_images() {
  if [ ! -f "$COMPOSE_FILE" ]; then
    log "compose ausente; backup só registrará destino pretendido"
    return 0
  fi
  {
    echo "# backup ${TS}"
    grep -E '^\s*image:' "$COMPOSE_FILE" || true
    echo "APP_IMAGE_BEFORE=${APP_IMAGE_BEFORE:-}"
    echo "WORKER_IMAGE_BEFORE=${WORKER_IMAGE_BEFORE:-}"
  } >"$BACKUP_MANIFEST"
  log "backup de referências: $BACKUP_MANIFEST"
}

APP_IMAGE_BEFORE=""
WORKER_IMAGE_BEFORE=""
if [ -f "$COMPOSE_FILE" ]; then
  APP_IMAGE_BEFORE="$(grep -A20 '^[[:space:]]*app:' "$COMPOSE_FILE" | grep -m1 'image:' | sed -E 's/.*image:[[:space:]]*//' | tr -d '"' || true)"
  WORKER_IMAGE_BEFORE="$(grep -A20 '^[[:space:]]*worker:' "$COMPOSE_FILE" | grep -m1 'image:' | sed -E 's/.*image:[[:space:]]*//' | tr -d '"' || true)"
fi

snapshot_compose_images

log "imagens alvo: app=$APP_IMAGE worker=$WORKER_IMAGE"
log "compose: $COMPOSE_FILE"
log "serviços: ${SERVICES[*]}"

run docker pull "$APP_IMAGE"
run docker pull "$WORKER_IMAGE"

if [ -f "$COMPOSE_FILE" ]; then
  COMPOSE_BACKUP="${BACKUP_DIR}/docker-compose.${TS}.yml.bak"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] copiaria compose para $COMPOSE_BACKUP"
    log "[dry-run] atualizaria image: de app → $APP_IMAGE"
    log "[dry-run] atualizaria image: de worker → $WORKER_IMAGE"
  else
    cp "$COMPOSE_FILE" "$COMPOSE_BACKUP"
    log "backup do compose: $COMPOSE_BACKUP"
    tmp="$(mktemp)"
    patch_service_image app "$APP_IMAGE" "$COMPOSE_FILE" "$tmp"
    patch_service_image worker "$WORKER_IMAGE" "$tmp" "$COMPOSE_FILE"
    rm -f "$tmp"
  fi
fi

export APP_IMAGE WORKER_IMAGE
run docker compose -f "$COMPOSE_FILE" up -d app worker

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_WAIT_SECS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local bad=0
    for svc in "${SERVICES[@]}"; do
      local status health
      status="$(docker compose -f "$COMPOSE_FILE" ps --status running --format json "$svc" 2>/dev/null | head -1 || true)"
      if [ -z "$status" ]; then
        bad=1
        continue
      fi
      health="$(printf '%s' "$status" | sed -n 's/.*"Health":"\([^"]*\)".*/\1/p')"
      if [ -n "$health" ] && [ "$health" != "healthy" ]; then
        bad=1
      fi
    done
    if [ "$bad" -eq 0 ]; then
      log "health OK (ou sem probe) para app e worker"
      return 0
    fi
    sleep 3
  done
  return 1
}

rollback() {
  log "iniciando rollback automático"
  if [ -n "$COMPOSE_BACKUP" ] && [ -f "$COMPOSE_BACKUP" ]; then
    cp "$COMPOSE_BACKUP" "$COMPOSE_FILE"
    log "compose restaurado de $COMPOSE_BACKUP"
  elif [ -n "$APP_IMAGE_BEFORE" ] || [ -n "$WORKER_IMAGE_BEFORE" ]; then
    if [ -n "$APP_IMAGE_BEFORE" ]; then
      APP_IMAGE="$APP_IMAGE_BEFORE"
    fi
    if [ -n "$WORKER_IMAGE_BEFORE" ]; then
      WORKER_IMAGE="$WORKER_IMAGE_BEFORE"
    fi
    export APP_IMAGE WORKER_IMAGE
  else
    log "sem backup do compose nem imagens anteriores; rollback manual necessário"
    return 1
  fi
  run docker compose -f "$COMPOSE_FILE" up -d app worker
}

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] pularia wait health e rollback"
  exit 0
fi

if ! wait_healthy; then
  log "saúde não confirmada em ${HEALTH_WAIT_SECS}s"
  rollback
  exit 1
fi

log "deploy concluído com sucesso"