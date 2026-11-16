#!/usr/bin/env bash
# Instalação isolada DeskcommCRM + Supabase (TESTE Tech42) — 14/11/2026
# NÃO toca containers existentes. NÃO sobe Caddy do Deskcomm.
# Segredos só em arquivos 600; nunca echo de senhas/tokens.
set -euo pipefail

DOMAIN="${DOMAIN:-fala42.tech42.com.br}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
KIT_DIR="$PROJECT_DIR/hostgator-setup-kit"
RUNTIME_DIR="$PROJECT_DIR/.runtime"
SUPABASE_DIR="$RUNTIME_DIR/supabase"
CREDENTIALS_FILE="$RUNTIME_DIR/admin-credentials"
NET_NAME="deskcommcrm_supabase"
APP_PORT=10028
API_GW_HTTP_PORT=10050
SUPABASE_REF="self-hosted/v0.8.1"
SUPABASE_SETUP_URL="https://raw.githubusercontent.com/supabase/supabase/${SUPABASE_REF}/docker/setup.sh"
SUPABASE_SETUP_SHA256="848973911bd5fa03dfd714b67bff4132e49b1b7777b6edb6ab0a9d9e85bc813c"

log() { printf '[tech42] %s\n' "$*"; }
die() { printf '[tech42] ERRO: %s\n' "$*" >&2; exit 1; }

ler_env() {
  local arquivo="$1" chave="$2" linha
  linha="$(grep -E "^${chave}=" "$arquivo" 2>/dev/null | tail -1 || true)"
  linha="${linha#*=}"
  linha="${linha#\"}"; linha="${linha%\"}"
  linha="${linha#\'}"; linha="${linha%\'}"
  printf '%s' "$linha"
}

set_env_var() {
  local file="$1" key="$2" val="$3"
  touch "$file"
  chmod 600 "$file"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    python3 - "$file" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines()
out, found = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={val}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={val}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

dc_sb() {
  (cd "$SUPABASE_DIR" && docker compose --env-file .env \
    -f docker-compose.yml \
    -f docker-compose.deskcomm.yml \
    -f docker-compose.tech42.yml \
    "$@")
}

dc_app() {
  (cd "$PROJECT_DIR" && docker compose --env-file .env \
    -f docker-compose.prod.yml \
    -f docker-compose.single-server.yml \
    -f docker-compose.tech42.yml \
    "$@")
}

command -v docker >/dev/null || die "docker ausente"
command -v curl >/dev/null || die "curl ausente"
command -v openssl >/dev/null || die "openssl ausente"
command -v python3 >/dev/null || die "python3 ausente"

uri_encode() {
  python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

mkdir -p "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

if ! docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  log "Criando rede Docker $NET_NAME"
  docker network create "$NET_NAME" >/dev/null
else
  log "Rede $NET_NAME ja existe"
fi

if [[ ! -f "$SUPABASE_DIR/.env" ]]; then
  log "Baixando setup oficial Supabase $SUPABASE_REF"
  setup_tmp="$(mktemp)"
  curl -fsSL --max-time 60 "$SUPABASE_SETUP_URL" -o "$setup_tmp"
  checksum="$(sha256sum "$setup_tmp" | awk '{print $1}')"
  [[ "$checksum" == "$SUPABASE_SETUP_SHA256" ]] || die "SHA256 do setup.sh nao bate"
  setup_log="$RUNTIME_DIR/supabase-setup.log"
  (umask 077 && : > "$setup_log")
  log "Executando setup.sh (saida completa so em supabase-setup.log)"
  (umask 022 && cd "$PROJECT_DIR" && sh "$setup_tmp" -y --skip-deps --ref "$SUPABASE_REF" --project-dir ".runtime/supabase") \
    >"$setup_log" 2>&1 \
    || die "setup.sh falhou — ver $setup_log"
  rm -f "$setup_tmp"
  grep -E '^===>' "$setup_log" || true
else
  log "Supabase .env ja existe — pulando setup.sh"
fi

cp "$KIT_DIR/supabase-single-server.override.yml" "$SUPABASE_DIR/docker-compose.deskcomm.yml"
cp "$PROJECT_DIR/docker-compose.supabase-tech42.yml" "$SUPABASE_DIR/docker-compose.tech42.yml"

supabase_env="$SUPABASE_DIR/.env"
set_env_var "$supabase_env" SUPABASE_PUBLIC_URL "https://${DOMAIN}"
set_env_var "$supabase_env" API_EXTERNAL_URL "https://${DOMAIN}/auth/v1"
set_env_var "$supabase_env" SITE_URL "https://${DOMAIN}"
set_env_var "$supabase_env" ADDITIONAL_REDIRECT_URLS "https://${DOMAIN}/auth/confirm,https://${DOMAIN}/**,https://deskcomm.jcplanejamento.com.br/auth/confirm,https://deskcomm.jcplanejamento.com.br/**,https://fala42.tech42.com.br/auth/confirm,https://fala42.tech42.com.br/**"
set_env_var "$supabase_env" ENABLE_EMAIL_AUTOCONFIRM "true"
set_env_var "$supabase_env" DISABLE_SIGNUP "true"
set_env_var "$supabase_env" PROXY_DOMAIN "$DOMAIN"
set_env_var "$supabase_env" SINGLE_SERVER_NETWORK "$NET_NAME"
set_env_var "$supabase_env" TRAEFIK_ENABLE "false"
set_env_var "$supabase_env" API_GW_HTTP_PORT "$API_GW_HTTP_PORT"
set_env_var "$supabase_env" COMPOSE_PROJECT_NAME "deskcommcrm"
set_env_var "$supabase_env" COMPOSE_FILE "docker-compose.yml:docker-compose.deskcomm.yml:docker-compose.tech42.yml"

log "Subindo Supabase minimo (sem studio/functions/meta/pooler)"
dc_sb up -d db
log "Aguardando db healthy..."
for _ in $(seq 1 60); do
  if dc_sb ps 2>/dev/null | grep -E 'db|supabase-db' | grep -qi healthy; then
    break
  fi
  sleep 3
done
dc_sb up -d auth rest realtime imgproxy storage api-gw
log "Aguardando api-gw..."
sleep 10
dc_sb ps

anon_key="$(ler_env "$supabase_env" ANON_KEY)"
service_key="$(ler_env "$supabase_env" SERVICE_ROLE_KEY)"
postgres_password="$(ler_env "$supabase_env" POSTGRES_PASSWORD)"
[[ -n "$anon_key" && -n "$service_key" && -n "$postgres_password" ]] || die "chaves Supabase ausentes no .env"
postgres_password_uri="$(uri_encode "$postgres_password")"

if [[ -f "$CREDENTIALS_FILE" ]]; then
  owner_email="$(ler_env "$CREDENTIALS_FILE" OWNER_EMAIL)"
  owner_password="$(ler_env "$CREDENTIALS_FILE" OWNER_PASSWORD)"
else
  owner_email="admin@${DOMAIN}"
  owner_password="$(openssl rand -hex 16)"
  umask 077
  {
    printf 'OWNER_EMAIL=%s\n' "$owner_email"
    printf 'OWNER_PASSWORD=%s\n' "$owner_password"
  } > "$CREDENTIALS_FILE"
  chmod 600 "$CREDENTIALS_FILE"
fi

app_env="$PROJECT_DIR/.env"
[[ -f "$app_env" ]] || { umask 077; : > "$app_env"; chmod 600 "$app_env"; }

gen_hex() { openssl rand -hex 32; }
gen_b64() { openssl rand -base64 32; }

ensure_env() {
  local key="$1" val
  val="$(ler_env "$app_env" "$key")"
  if [[ -z "$val" ]]; then
    val="$2"
    set_env_var "$app_env" "$key" "$val"
  fi
  printf '%s' "$(ler_env "$app_env" "$key")"
}

ensure_env INTERNAL_SECRET "$(gen_hex)" >/dev/null
ensure_env INTERNAL_CRON_SECRET "$(gen_hex)" >/dev/null
ensure_env NUVEMSHOP_OAUTH_ENCRYPTION_KEY "$(gen_hex)" >/dev/null
ensure_env CPF_ENCRYPTION_KEY "$(gen_b64)" >/dev/null
ensure_env AI_CRED_AES_KEY "$(gen_b64)" >/dev/null
ensure_env IMPERSONATE_COOKIE_SECRET "$(gen_hex)" >/dev/null
ensure_env LGPD_SIGNING_KEY "$(gen_hex)" >/dev/null
ensure_env WAHA_HMAC_SECRET "$(gen_hex)" >/dev/null
ensure_env SRH_TOKEN "$(gen_hex)" >/dev/null
ensure_env WAHA_API_KEY "$(gen_hex)" >/dev/null

WAHA_API_KEY="$(ler_env "$app_env" WAHA_API_KEY)"
WAHA_API_KEY_SHA512="$(printf '%s' "$WAHA_API_KEY" | openssl dgst -sha512 -hex | awk '{print $NF}')"
set_env_var "$app_env" WAHA_API_KEY_SHA512 "$WAHA_API_KEY_SHA512"
SRH_TOKEN="$(ler_env "$app_env" SRH_TOKEN)"

set_env_var "$app_env" DOMAIN "$DOMAIN"
set_env_var "$app_env" ACME_EMAIL "admin@${DOMAIN}"
set_env_var "$app_env" REVERSE_PROXY "external-caddy"
set_env_var "$app_env" SINGLE_SERVER "1"
set_env_var "$app_env" SINGLE_SERVER_NETWORK "$NET_NAME"
set_env_var "$app_env" PSQL_DOCKER_NETWORK "$NET_NAME"
set_env_var "$app_env" SUPABASE_INTERNAL_URL "http://127.0.0.1:${API_GW_HTTP_PORT}"
set_env_var "$app_env" SUPABASE_SERVER_URL "http://supabase-envoy:8000"
set_env_var "$app_env" NEXT_PUBLIC_SUPABASE_URL "https://${DOMAIN}"
set_env_var "$app_env" NEXT_PUBLIC_SUPABASE_ANON_KEY "$anon_key"
set_env_var "$app_env" SUPABASE_SERVICE_ROLE_KEY "$service_key"
set_env_var "$app_env" SUPABASE_DB_URL "postgresql://postgres:${postgres_password_uri}@supabase-db:5432/postgres"
set_env_var "$app_env" NEXT_PUBLIC_APP_URL "https://${DOMAIN}"
set_env_var "$app_env" OWNER_EMAIL "$owner_email"
set_env_var "$app_env" OWNER_PASSWORD "$owner_password"
set_env_var "$app_env" APP_NAME "Fala42"
set_env_var "$app_env" APP_LOCALE "pt-BR"
set_env_var "$app_env" SENTRY_DSN "off"
set_env_var "$app_env" APP_IMAGE "ghcr.io/melgarafael/deskcommcrm@sha256:babea4bb6f302f61b4a550b4248e0db21dc931d68fb8e5a321a6899e1e45c075"
set_env_var "$app_env" WORKER_IMAGE "ghcr.io/melgarafael/deskcomm-worker@sha256:7223a9b78fc2a21e5d8e5436e79e0e4d7316f574392d85cc2e9bc01c3df37331"
set_env_var "$app_env" SCHEDULER_IMAGE "ghcr.io/melgarafael/deskcomm-scheduler@sha256:f4f802823ef920f7077d731be416a27b516bae0e84817003423250539c21d2a6"
set_env_var "$app_env" WAHA_IMAGE "devlikeapro/waha:latest-2026.7.2"
set_env_var "$app_env" APP_PULL_POLICY "missing"
set_env_var "$app_env" WORKER_PULL_POLICY "missing"
set_env_var "$app_env" SCHEDULER_PULL_POLICY "missing"
set_env_var "$app_env" APP_MEM_LIMIT "384m"
set_env_var "$app_env" WORKER_MEM_LIMIT "192m"
set_env_var "$app_env" SCHEDULER_MEM_LIMIT "96m"
set_env_var "$app_env" WAHA_MEM_LIMIT "192m"
set_env_var "$app_env" REDIS_MEM_LIMIT "48m"
set_env_var "$app_env" SRH_MEM_LIMIT "48m"
set_env_var "$app_env" EVENT_LOG_WORKER_DRAINS "true"
set_env_var "$app_env" UPSTASH_REDIS_REST_URL "http://srh:80"
set_env_var "$app_env" UPSTASH_REDIS_REST_TOKEN "$SRH_TOKEN"
set_env_var "$app_env" SRH_MODE "env"
# SRH_TOKEN ja gravado por ensure_env
set_env_var "$app_env" WAHA_API_BASE_URL "http://waha:3000"
set_env_var "$app_env" WHATSAPP_RESTART_ALL_SESSIONS "false"
set_env_var "$app_env" WAHA_DASHBOARD_ENABLED "false"

log "Puxando imagens do CRM"
dc_app pull app worker scheduler || true

log "Subindo CRM (sem caddy Deskcomm): app worker scheduler waha redis srh"
dc_app up -d redis srh waha app worker scheduler

log "Aguardando app na porta ${APP_PORT}..."
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${APP_PORT}/" 2>/dev/null; then
    log "App respondeu em 127.0.0.1:${APP_PORT}"
    break
  fi
  sleep 3
done

log "OK fase 1. Credenciais: $CREDENTIALS_FILE | .env: $app_env"
