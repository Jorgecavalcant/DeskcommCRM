#!/usr/bin/env bash
# Autodeploy Fala42: aplica novas imagens GHCR (tag prod) a cada ciclo de cron.
# Usuário: jorge (grupo docker). Sem sudo. Sem down/prune. Só app+worker.
#
# Instalar: ver scripts/fala42-autodeploy.md (cron do jorge a cada 5 min).
#
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/srv/projetos/clientes/fala42}"
COMPOSE_OVERRIDE="${COMPOSE_OVERRIDE:-docker-compose.tech42.yml}"
# Flags passadas ao docker compose (cwd = PROJECT_DIR). Sobrescreva via env.
COMPOSE_ARGS="${COMPOSE_ARGS:---env-file .env -f docker-compose.prod.yml -f docker-compose.single-server.yml -f docker-compose.tech42.yml}"
STATE_DIR="${STATE_DIR:-${PROJECT_DIR}/tech42/autodeploy}"
LOG="${LOG:-${STATE_DIR}/autodeploy.log}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:10028/api/v1/health}"
MIN_FREE_GB="${MIN_FREE_GB:-3}"
APP_CONTAINER="${APP_CONTAINER:-deskcommcrm-app-1}"
WORKER_CONTAINER="${WORKER_CONTAINER:-deskcommcrm-worker-1}"
APP_IMAGE_REPO="${APP_IMAGE_REPO:-ghcr.io/jorgecavalcant/fala42-app}"
WORKER_IMAGE_REPO="${WORKER_IMAGE_REPO:-ghcr.io/jorgecavalcant/fala42-worker}"
REMOTE_TAG="${REMOTE_TAG:-prod}"
HEALTH_WAIT_SECS="${HEALTH_WAIT_SECS:-180}"
REGISTRY_OWNER="${REGISTRY_OWNER:-jorgecavalcant}"
APP_NAME="${APP_NAME:-fala42-app}"
WORKER_NAME="${WORKER_NAME:-fala42-worker}"

DRY_RUN=0
STATUS_ONLY=0

usage() {
  cat <<'EOF'
fala42-autodeploy.sh — aplica imagens GHCR (tag prod) em app e worker

Opções:
  --dry-run   Mostra o que faria, sem pull/up/editar arquivos
  --status    Versão rodando, digest aplicado, flag PAUSADO
  -h, --help  Ajuda

Variáveis (defaults entre parênteses):
  PROJECT_DIR  (/srv/projetos/clientes/fala42)
  COMPOSE_OVERRIDE  (docker-compose.tech42.yml)
  COMPOSE_ARGS  (--env-file .env -f docker-compose.prod.yml -f docker-compose.single-server.yml -f docker-compose.tech42.yml)
  STATE_DIR  ($PROJECT_DIR/tech42/autodeploy)
  LOG  ($STATE_DIR/autodeploy.log)
  HEALTH_URL  (http://127.0.0.1:10028/api/v1/health)
  MIN_FREE_GB  (3)
  APP_CONTAINER / WORKER_CONTAINER
EOF
}

# --- logging (America/Sao_Paulo); nunca logar .env nem tokens ---
log() {
  local ts
  ts="$(TZ=America/Sao_Paulo date '+%Y-%m-%d %H:%M:%S %z')"
  local line="[${ts}] $*"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s\n' "$line" | tee -a "$LOG" >/dev/null
  printf '%s\n' "$line"
}

die() {
  log "ERRO: $*"
  exit 1
}

# docker compose com COMPOSE_ARGS (string de flags). cwd = PROJECT_DIR.
compose() {
  # shellcheck disable=SC2086
  (cd "$PROJECT_DIR" && docker compose $COMPOSE_ARGS "$@")
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "comando não encontrado: $1"
}

# Digest remoto da tag SEM baixar a imagem. Rede falhou → string vazia.
remote_digest() {
  local image_name="$1"
  local token digest
  local accept
  accept="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

  token="$(
    curl -fsS --max-time 20 \
      "https://ghcr.io/token?scope=repository:${REGISTRY_OWNER}/${image_name}:pull" \
      2>/dev/null \
      | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      || true
  )"
  if [ -z "$token" ]; then
    return 0
  fi

  digest="$(
    curl -fsSI --max-time 20 \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: ${accept}" \
      "https://ghcr.io/v2/${REGISTRY_OWNER}/${image_name}/manifests/${REMOTE_TAG}" \
      2>/dev/null \
      | tr -d '\r' \
      | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2; exit}' \
      || true
  )"
  # Não ecoar o token. Só o digest.
  printf '%s' "$digest"
}

free_gb_root() {
  # Espaço livre em / em GB inteiros (df -BG).
  df -BG / 2>/dev/null | awk 'NR==2 { gsub(/G/,"",$4); print $4+0; exit }'
}

image_revision() {
  local ref="$1"
  docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$ref" 2>/dev/null || true
}

container_image_ref() {
  local cname="$1"
  docker inspect --format '{{.Config.Image}}' "$cname" 2>/dev/null || true
}

container_image_id() {
  local cname="$1"
  docker inspect --format '{{.Image}}' "$cname" 2>/dev/null || true
}

container_health() {
  local cname="$1"
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cname" 2>/dev/null || echo "missing"
}

container_restart_count() {
  local cname="$1"
  docker inspect --format '{{.RestartCount}}' "$cname" 2>/dev/null || echo "0"
}

patch_service_image() {
  local svc="$1"
  local img="$2"
  local src="$3"
  local dst="$4"
  # image: precisa ser tratada ANTES da regra que sai do bloco (senão image: encerra o serviço).
  awk -v svc="$svc" -v img="$img" '
    $0 ~ "^[[:space:]]*" svc ":" { in_svc=1; print; next }
    in_svc && /^[[:space:]]*image:/ { sub(/image:.*/, "image: " img); print; in_svc=0; next }
    in_svc && /^[[:space:]]*[a-zA-Z0-9_.-]+:/ && $0 !~ "^[[:space:]]*" svc ":" { in_svc=0 }
    { print }
  ' "$src" >"$dst"
}

prune_backups() {
  local dir="$1"
  local keep=10
  [ -d "$dir" ] || return 0
  # Apaga só pastas dentro de backups/, mantém as 10 mais recentes (nome = timestamp).
  # shellcheck disable=SC2012
  ls -1d "$dir"/*/ 2>/dev/null | sort -r | tail -n +"$((keep + 1))" | while IFS= read -r old; do
    rm -rf "$old"
  done
}

digest_is_ruim() {
  local app_d="$1"
  local worker_d="$2"
  local f="${STATE_DIR}/digests-ruins"
  [ -f "$f" ] || return 1
  grep -Fq "${app_d} ${worker_d}" "$f" 2>/dev/null
}

mark_digest_ruim() {
  local app_d="$1"
  local worker_d="$2"
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$app_d" "$worker_d" >>"${STATE_DIR}/digests-ruins"
}

maybe_hourly_ok() {
  local marker="${STATE_DIR}/ultimo-ok-hora"
  local hour
  hour="$(TZ=America/Sao_Paulo date '+%Y%m%d%H')"
  if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null || true)" = "$hour" ]; then
    return 0
  fi
  printf '%s\n' "$hour" >"$marker"
  log "ok — digests já aplicados (sem mudança)"
}

show_status() {
  mkdir -p "$STATE_DIR"
  local app_ref worker_ref app_rev worker_rev
  app_ref="$(container_image_ref "$APP_CONTAINER")"
  worker_ref="$(container_image_ref "$WORKER_CONTAINER")"
  app_rev="$(image_revision "$app_ref")"
  worker_rev="$(image_revision "$worker_ref")"
  echo "project_dir=$PROJECT_DIR"
  echo "compose_override=$PROJECT_DIR/$COMPOSE_OVERRIDE"
  echo "app_container=$APP_CONTAINER image=${app_ref:-?} revision=${app_rev:-?}"
  echo "worker_container=$WORKER_CONTAINER image=${worker_ref:-?} revision=${worker_rev:-?}"
  echo "ultimo-digest-app=$(cat "${STATE_DIR}/ultimo-digest-app" 2>/dev/null || echo '(ausente)')"
  echo "ultimo-digest-worker=$(cat "${STATE_DIR}/ultimo-digest-worker" 2>/dev/null || echo '(ausente)')"
  if [ -f "${STATE_DIR}/PAUSADO" ]; then
    echo "pausa=SIM (${STATE_DIR}/PAUSADO)"
  else
    echo "pausa=nao"
  fi
}

wait_healthy() {
  local tag="$1"
  local rc_app0="$2"
  local rc_worker0="$3"
  local deadline=$((SECONDS + HEALTH_WAIT_SECS))
  local h_app h_worker body rc_app rc_worker

  while [ "$SECONDS" -lt "$deadline" ]; do
    h_app="$(container_health "$APP_CONTAINER")"
    h_worker="$(container_health "$WORKER_CONTAINER")"
    rc_app="$(container_restart_count "$APP_CONTAINER")"
    rc_worker="$(container_restart_count "$WORKER_CONTAINER")"

    if [ "${rc_app:-0}" -gt "${rc_app0:-0}" ] || [ "${rc_worker:-0}" -gt "${rc_worker0:-0}" ]; then
      log "health: RestartCount subiu (app ${rc_app0}->${rc_app}, worker ${rc_worker0}->${rc_worker})"
      return 1
    fi

    body="$(curl -fsS --max-time 5 "$HEALTH_URL" 2>/dev/null || true)"
    if [ "$h_app" = "healthy" ] && [ "$h_worker" = "healthy" ] \
      && printf '%s' "$body" | grep -q '"status"[[:space:]]*:[[:space:]]*"healthy"'; then
      log "health OK (${tag})"
      return 0
    fi
    sleep 3
  done
  log "health timeout ${HEALTH_WAIT_SECS}s (app=${h_app:-?} worker=${h_worker:-?})"
  return 1
}

do_rollback() {
  local tag="$1"
  local motivo="$2"
  local backup_compose="$3"
  local app_d="$4"
  local worker_d="$5"

  # Evita reentrada do trap ERR durante o próprio rollback.
  trap - ERR
  compose_alterado=0

  log "ROLLBACK ${tag} ${motivo}"
  if [ -f "$backup_compose" ]; then
    cp "$backup_compose" "${PROJECT_DIR}/${COMPOSE_OVERRIDE}"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] pularia up de rollback"
    mark_digest_ruim "$app_d" "$worker_d"
    exit 1
  fi
  compose up -d --no-deps app worker || true
  # Melhor esforço: esperar healthy de novo (não bloquear eternamente).
  local rc_a rc_w
  rc_a="$(container_restart_count "$APP_CONTAINER")"
  rc_w="$(container_restart_count "$WORKER_CONTAINER")"
  wait_healthy "${tag}-rollback" "$rc_a" "$rc_w" || log "aviso: rollback subiu mas health não confirmou"
  mark_digest_ruim "$app_d" "$worker_d"
  exit 1
}

# Se o compose override já foi patchado e algo inesperado falhar, reverte.
compose_alterado=0
# shellcheck disable=SC2317 # invocado via trap ERR
on_err_inesperado() {
  if [ "${compose_alterado:-0}" -eq 1 ]; then
    do_rollback "${TAG:-unknown}" "erro_inesperado" "${backup_compose:-}" "${app_digest:-}" "${worker_digest:-}"
  fi
}
trap on_err_inesperado ERR

# --- CLI ---
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --status) STATUS_ONLY=1 ;;
    *) die "opção desconhecida: $1 (use --help)" ;;
  esac
  shift
done

if [ "$STATUS_ONLY" -eq 1 ]; then
  show_status
  exit 0
fi

require_cmd docker
require_cmd curl
require_cmd flock
require_cmd awk
require_cmd df

mkdir -p "$STATE_DIR" "${STATE_DIR}/backups"

# (a) flock + pausa
exec 9>"${STATE_DIR}/lock"
if ! flock -n 9; then
  # Já rodando: sair quieto
  exit 0
fi

if [ -f "${STATE_DIR}/PAUSADO" ]; then
  log "pausado (${STATE_DIR}/PAUSADO) — nada a fazer"
  exit 0
fi

# (b) digests remotos
app_digest="$(remote_digest "$APP_NAME")"
worker_digest="$(remote_digest "$WORKER_NAME")"
if [ -z "$app_digest" ] || [ -z "$worker_digest" ]; then
  log "rede/GHCR indisponível ao consultar digest de ${REMOTE_TAG} — saindo sem erro"
  exit 0
fi

# (c) sem mudança / digests ruins
ultimo_app="$(cat "${STATE_DIR}/ultimo-digest-app" 2>/dev/null || true)"
ultimo_worker="$(cat "${STATE_DIR}/ultimo-digest-worker" 2>/dev/null || true)"

if [ -n "$ultimo_app" ] && [ -n "$ultimo_worker" ] \
  && [ "$app_digest" = "$ultimo_app" ] && [ "$worker_digest" = "$ultimo_worker" ]; then
  maybe_hourly_ok
  exit 0
fi

if digest_is_ruim "$app_digest" "$worker_digest"; then
  log "digest remoto está em digests-ruins — não tento de novo"
  exit 0
fi

# (d) espaço
free_gb="$(free_gb_root)"
free_gb="${free_gb:-0}"
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
  log "espaço livre em / = ${free_gb}G < MIN_FREE_GB=${MIN_FREE_GB} — abortando"
  exit 0
fi

app_ref_digest="${APP_IMAGE_REPO}@${app_digest}"
worker_ref_digest="${WORKER_IMAGE_REPO}@${worker_digest}"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] pull ${app_ref_digest}"
  log "[dry-run] pull ${worker_ref_digest}"
else
  log "pull ${app_ref_digest}"
  if ! docker pull "$app_ref_digest"; then
    log "pull falhou"
    exit 0
  fi
  log "pull ${worker_ref_digest}"
  if ! docker pull "$worker_ref_digest"; then
    log "pull falhou"
    exit 0
  fi
fi

# (e) revisions iguais?
if [ "$DRY_RUN" -eq 1 ]; then
  # Em dry-run sem imagens locais, assume revisão fictícia alinhada se já houver containers.
  app_rev="$(image_revision "$app_ref_digest")"
  worker_rev="$(image_revision "$worker_ref_digest")"
  if [ -z "$app_rev" ]; then app_rev="$(image_revision "$(container_image_ref "$APP_CONTAINER")")"; fi
  if [ -z "$worker_rev" ]; then worker_rev="$(image_revision "$(container_image_ref "$WORKER_CONTAINER")")"; fi
  app_rev="${app_rev:-dryrun0000000}"
  worker_rev="${worker_rev:-$app_rev}"
else
  app_rev="$(image_revision "$app_ref_digest")"
  worker_rev="$(image_revision "$worker_ref_digest")"
fi

if [ -z "$app_rev" ] || [ -z "$worker_rev" ]; then
  log "não li org.opencontainers.image.revision das imagens puxadas — saindo"
  exit 0
fi

if [ "$app_rev" != "$worker_rev" ]; then
  log "revisions divergentes (app=${app_rev} worker=${worker_rev}) — CI ainda publicando; próximo ciclo"
  exit 0
fi

TAG="sha-${app_rev:0:7}"
app_tagged="${APP_IMAGE_REPO}:${TAG}"
worker_tagged="${WORKER_IMAGE_REPO}:${TAG}"

if [ "$DRY_RUN" -eq 0 ]; then
  docker tag "$app_ref_digest" "$app_tagged"
  docker tag "$worker_ref_digest" "$worker_tagged"
else
  log "[dry-run] docker tag → ${app_tagged} / ${worker_tagged}"
fi

# Bootstrap: sem estado local e revision rodando == remota → só grava digests
if [ ! -f "${STATE_DIR}/ultimo-digest-app" ] || [ ! -f "${STATE_DIR}/ultimo-digest-worker" ]; then
  run_app_ref="$(container_image_ref "$APP_CONTAINER")"
  run_worker_ref="$(container_image_ref "$WORKER_CONTAINER")"
  run_app_rev="$(image_revision "$run_app_ref")"
  run_worker_rev="$(image_revision "$run_worker_ref")"
  if [ -n "$run_app_rev" ] && [ "$run_app_rev" = "$app_rev" ] \
    && [ -n "$run_worker_rev" ] && [ "$run_worker_rev" = "$worker_rev" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      log "[dry-run] BOOTSTRAP OK ${TAG} — gravaria digests sem redeploy"
      exit 0
    fi
    printf '%s\n' "$app_digest" >"${STATE_DIR}/ultimo-digest-app"
    printf '%s\n' "$worker_digest" >"${STATE_DIR}/ultimo-digest-worker"
    log "BOOTSTRAP OK ${TAG} — estado gravado sem redeploy"
    exit 0
  fi
fi

# (f) backup
ts_backup="$(TZ=America/Sao_Paulo date '+%Y%m%dT%H%M%S')"
backup_dir="${STATE_DIR}/backups/${ts_backup}"
compose_path="${PROJECT_DIR}/${COMPOSE_OVERRIDE}"
backup_compose="${backup_dir}/${COMPOSE_OVERRIDE}"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] backup em ${backup_dir}"
  log "[dry-run] atualizaria image: app → ${app_tagged}"
  log "[dry-run] atualizaria image: worker → ${worker_tagged}"
  log "[dry-run] compose up -d --no-deps app worker"
  log "[dry-run] health ${HEALTH_URL}"
  exit 0
fi

mkdir -p "$backup_dir"
if [ -f "$compose_path" ]; then
  cp "$compose_path" "$backup_compose"
else
  die "compose override ausente: $compose_path"
fi
{
  echo "# Name / Config.Image / Image"
  docker inspect --format 'app Name={{.Name}} Config.Image={{.Config.Image}} Image={{.Image}}' "$APP_CONTAINER" 2>/dev/null || echo "app missing"
  docker inspect --format 'worker Name={{.Name}} Config.Image={{.Config.Image}} Image={{.Image}}' "$WORKER_CONTAINER" 2>/dev/null || echo "worker missing"
} >"${backup_dir}/inspect.txt"

cur_app_id="$(container_image_id "$APP_CONTAINER")"
cur_worker_id="$(container_image_id "$WORKER_CONTAINER")"
if [ -n "$cur_app_id" ]; then
  docker tag "$cur_app_id" "fala42-rollback:app-auto-anterior" || true
fi
if [ -n "$cur_worker_id" ]; then
  docker tag "$cur_worker_id" "fala42-rollback:worker-auto-anterior" || true
fi
prune_backups "${STATE_DIR}/backups"

# (g) patch compose + validação
tmp="$(mktemp)"
tmp2="$(mktemp)"
patch_service_image app "$app_tagged" "$compose_path" "$tmp"
patch_service_image worker "$worker_tagged" "$tmp" "$tmp2"
cp "$tmp2" "$compose_path"
compose_alterado=1
rm -f "$tmp" "$tmp2"

images_out="$(compose config --images 2>/dev/null || true)"
if ! printf '%s\n' "$images_out" | grep -Fq "$app_tagged" \
  || ! printf '%s\n' "$images_out" | grep -Fq "$worker_tagged"; then
  log "validação compose config --images falhou; restaurando"
  cp "$backup_compose" "$compose_path"
  compose_alterado=0
  exit 1
fi

# (h) baseline RestartCount + up
rc_app0="$(container_restart_count "$APP_CONTAINER")"
rc_worker0="$(container_restart_count "$WORKER_CONTAINER")"
log "up -d --no-deps app worker (${TAG})"
if ! compose up -d --no-deps app worker; then
  do_rollback "$TAG" "up_falhou" "$backup_compose" "$app_digest" "$worker_digest"
fi

# (i) health
if ! wait_healthy "$TAG" "$rc_app0" "$rc_worker0"; then
  do_rollback "$TAG" "health_falhou" "$backup_compose" "$app_digest" "$worker_digest"
fi

# (j) sucesso
printf '%s\n' "$app_digest" >"${STATE_DIR}/ultimo-digest-app"
printf '%s\n' "$worker_digest" >"${STATE_DIR}/ultimo-digest-worker"
log "DEPLOY OK ${TAG}"
exit 0
