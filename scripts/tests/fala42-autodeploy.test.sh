#!/usr/bin/env bash
# Testes do fala42-autodeploy.sh com docker/curl mockados via PATH.
# Compatível com Bash 3.2 (macOS).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/fala42-autodeploy.sh"
PASS=0
FAIL=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (got='$got' want='$want')"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_has() {
  local name="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -Fq "$needle" "$file"; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (não achou '$needle' em ${file})"
    if [ -f "$file" ]; then
      echo "---- conteúdo ----"
      cat "$file" | head -40
      echo "------------------"
    fi
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_has() {
  local name="$1" file="$2" needle="$3"
  if [ -f "$file" ] && grep -Fq "$needle" "$file"; then
    echo "FAIL $name (ainda tem '$needle')"
    FAIL=$((FAIL + 1))
  else
    echo "PASS $name"
    PASS=$((PASS + 1))
  fi
}

write_stubs() {
  local dir="$1"

  cat >"$dir/bin/flock" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat >"$dir/bin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1G-blocks Used Available Use% Mounted on"
echo "/dev/sda1 100G 80G 20G 80% /"
EOF

  cat >"$dir/bin/curl" <<EOF
#!/bin/bash
set -e
STUB="$dir/stubstate"
url=""
for a in "\$@"; do url="\$a"; done

case "\$url" in
  *"/token?"*)
    printf '%s\n' '{"token":"fake-token"}'
    exit 0
    ;;
  *"/fala42-app/manifests/"*)
    printf '%s\n' "HTTP/1.1 200 OK"
    printf '%s\n' "Docker-Content-Digest: \$(cat "\$STUB/remote-app-digest")"
    printf '\n'
    exit 0
    ;;
  *"/fala42-worker/manifests/"*)
    printf '%s\n' "HTTP/1.1 200 OK"
    printf '%s\n' "Docker-Content-Digest: \$(cat "\$STUB/remote-worker-digest")"
    printf '\n'
    exit 0
    ;;
  *health*)
    if [ -f "\$STUB/health-fail" ]; then
      printf '%s\n' '{"status":"unhealthy"}'
      exit 0
    fi
    printf '%s\n' '{"status":"healthy"}'
    exit 0
    ;;
esac
echo "curl-stub: não tratado: \$url" >&2
exit 1
EOF

  cat >"$dir/bin/docker" <<EOF
#!/bin/bash
set -e
STUB="$dir/stubstate"
PROJ="$dir/project"
CMD="\${1:-}"
shift || true
mkdir -p "\$STUB"
touch "\$STUB/docker.log"

last() {
  local x=""
  for x in "\$@"; do :; done
  printf '%s' "\$x"
}

case "\$CMD" in
  pull)
    echo "pull \$1" >>"\$STUB/docker.log"
    exit 0
    ;;
  tag)
    echo "tag \$1 \$2" >>"\$STUB/docker.log"
    exit 0
    ;;
  image)
    sub="\${1:-}"
    shift || true
    if [ "\$sub" != "inspect" ]; then
      echo "docker image \$sub não suportado" >&2
      exit 1
    fi
    ref="\$(last "\$@")"
    case "\$ref" in
      *sha-oldold1*)
        cat "\$STUB/rev-running"
        ;;
      *@sha256:bbb*|*fala42-worker@*)
        cat "\$STUB/rev-worker"
        ;;
      *@sha256:aaa*|*fala42-app@*|*fala42-app:sha-*|*fala42-worker:sha-aaaaaaa*)
        cat "\$STUB/rev-app"
        ;;
      *)
        # digest completo do arquivo
        if echo "\$ref" | grep -Fq "\$(cat "\$STUB/remote-worker-digest")"; then
          cat "\$STUB/rev-worker"
        elif echo "\$ref" | grep -Fq "\$(cat "\$STUB/remote-app-digest")"; then
          cat "\$STUB/rev-app"
        else
          cat "\$STUB/rev-app"
        fi
        ;;
    esac
    exit 0
    ;;
  inspect)
    fmt=""
    name=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--format" ]; then
        shift
        fmt="\$1"
      else
        name="\$1"
      fi
      shift || true
    done
    case "\$fmt" in
      *Config.Image*)
        if echo "\$name" | grep -q worker; then
          echo "ghcr.io/jorgecavalcant/fala42-worker:sha-oldold1"
        else
          echo "ghcr.io/jorgecavalcant/fala42-app:sha-oldold1"
        fi
        ;;
      *RestartCount*) echo 0 ;;
      *Health.Status*|*State.Health*)
        if [ -f "\$STUB/health-fail" ]; then echo unhealthy; else echo healthy; fi
        ;;
      *'.Image'*|*Image*)
        if echo "\$name" | grep -q worker; then echo sha256:workerimg; else echo sha256:appimg; fi
        ;;
      *Name*) echo "/\$name" ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  compose)
    echo "compose \$*" >>"\$STUB/docker.log"
    # detecta subcomando
    has_config=0
    has_up=0
    for a in "\$@"; do
      [ "\$a" = "config" ] && has_config=1
      [ "\$a" = "up" ] && has_up=1
    done
    if [ "\$has_config" -eq 1 ]; then
      grep 'image:' "\$PROJ/docker-compose.tech42.yml" | sed -E 's/.*image:[[:space:]]*//'
      exit 0
    fi
    if [ "\$has_up" -eq 1 ]; then
      echo "up \$*" >>"\$STUB/docker.log"
      if [ -f "\$STUB/up-fail" ]; then
        exit 1
      fi
      exit 0
    fi
    exit 0
    ;;
  *)
    echo "docker-stub: \$CMD \$*" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$dir/bin/flock" "$dir/bin/df" "$dir/bin/curl" "$dir/bin/docker"
}

setup_case() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/project" "$dir/state/backups" "$dir/stubstate"
  cat >"$dir/project/docker-compose.tech42.yml" <<'YAML'
services:
  app:
    image: ghcr.io/jorgecavalcant/fala42-app:sha-oldold1
  worker:
    image: ghcr.io/jorgecavalcant/fala42-worker:sha-oldold1
YAML
  write_stubs "$dir"

  echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$dir/stubstate/remote-app-digest"
  echo "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >"$dir/stubstate/remote-worker-digest"
  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$dir/stubstate/rev-app"
  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$dir/stubstate/rev-worker"
  echo "oldold100000000000000000000000000000000" >"$dir/stubstate/rev-running"

  export PATH="$dir/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PROJECT_DIR="$dir/project"
  export COMPOSE_OVERRIDE="docker-compose.tech42.yml"
  export COMPOSE_ARGS="-f docker-compose.tech42.yml"
  export STATE_DIR="$dir/state"
  export LOG="$dir/state/autodeploy.log"
  export HEALTH_URL="http://127.0.0.1:9/api/v1/health"
  export MIN_FREE_GB=3
  export APP_CONTAINER="deskcommcrm-app-1"
  export WORKER_CONTAINER="deskcommcrm-worker-1"
  export HEALTH_WAIT_SECS=6
}

echo "== fala42-autodeploy testes =="
bash -n "$SCRIPT"
echo "PASS bash -n"
PASS=$((PASS + 1))

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$SCRIPT"; then
    echo "PASS shellcheck"
    PASS=$((PASS + 1))
  else
    echo "FAIL shellcheck"
    FAIL=$((FAIL + 1))
  fi
else
  echo "SKIP shellcheck (não instalado)"
fi

# --- sem mudança ---
DIR="$(mktemp -d "${TMPDIR:-/tmp}/fala42-ad-XXXXXX")"
setup_case "$DIR"
cp "$DIR/stubstate/remote-app-digest" "$DIR/state/ultimo-digest-app"
cp "$DIR/stubstate/remote-worker-digest" "$DIR/state/ultimo-digest-worker"
TZ=America/Sao_Paulo date '+%Y%m%d%H' >"$DIR/state/ultimo-ok-hora"
set +e
"$SCRIPT" >/tmp/ad-out-sem.txt 2>&1
code=$?
set -e
assert_eq "sem_mudanca.exit" "$code" "0"
pulls=0
if [ -f "$DIR/stubstate/docker.log" ]; then
  pulls="$(grep -c 'pull' "$DIR/stubstate/docker.log" || true)"
fi
assert_eq "sem_mudanca.sem_pull" "$pulls" "0"
assert_file_has "sem_mudanca.compose_intocado" "$DIR/project/docker-compose.tech42.yml" "sha-oldold1"
rm -rf "$DIR"

# --- deploy ok ---
DIR="$(mktemp -d "${TMPDIR:-/tmp}/fala42-ad-XXXXXX")"
setup_case "$DIR"
set +e
"$SCRIPT" >/tmp/ad-out-ok.txt 2>&1
code=$?
set -e
assert_eq "deploy_ok.exit" "$code" "0"
assert_file_has "deploy_ok.log" "$LOG" "DEPLOY OK sha-aaaaaaa"
assert_file_has "deploy_ok.compose_app" "$DIR/project/docker-compose.tech42.yml" "fala42-app:sha-aaaaaaa"
assert_file_has "deploy_ok.compose_worker" "$DIR/project/docker-compose.tech42.yml" "fala42-worker:sha-aaaaaaa"
assert_eq "deploy_ok.digest_app" "$(cat "$DIR/state/ultimo-digest-app")" "$(cat "$DIR/stubstate/remote-app-digest")"
if [ "$FAIL" -gt 0 ] && [ ! -f "$DIR/state/ultimo-digest-app" ]; then
  echo "DEBUG deploy_ok stdout:"; cat /tmp/ad-out-ok.txt
  echo "DEBUG log:"; cat "$LOG" 2>/dev/null || true
  echo "DEBUG docker.log:"; cat "$DIR/stubstate/docker.log" 2>/dev/null || true
fi
rm -rf "$DIR"

# --- health falha → rollback ---
DIR="$(mktemp -d "${TMPDIR:-/tmp}/fala42-ad-XXXXXX")"
setup_case "$DIR"
touch "$DIR/stubstate/health-fail"
set +e
"$SCRIPT" >/tmp/ad-out-rb.txt 2>&1
code=$?
set -e
assert_eq "health_rollback.exit" "$code" "1"
assert_file_has "health_rollback.log" "$LOG" "ROLLBACK sha-aaaaaaa"
assert_file_has "health_rollback.compose_restaurado" "$DIR/project/docker-compose.tech42.yml" "sha-oldold1"
assert_file_has "health_rollback.ruins" "$DIR/state/digests-ruins" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if [ "$code" != "1" ]; then
  echo "DEBUG rollback stdout:"; cat /tmp/ad-out-rb.txt
  echo "DEBUG log:"; cat "$LOG" 2>/dev/null || true
fi
rm -rf "$DIR"

# --- up falha → rollback ---
DIR="$(mktemp -d "${TMPDIR:-/tmp}/fala42-ad-XXXXXX")"
setup_case "$DIR"
touch "$DIR/stubstate/up-fail"
set +e
"$SCRIPT" >/tmp/ad-out-upfail.txt 2>&1
code=$?
set -e
assert_eq "up_rollback.exit" "$code" "1"
assert_file_has "up_rollback.log" "$LOG" "ROLLBACK sha-aaaaaaa up_falhou"
assert_file_has "up_rollback.compose_restaurado" "$DIR/project/docker-compose.tech42.yml" "sha-oldold1"
assert_file_has "up_rollback.ruins" "$DIR/state/digests-ruins" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if [ "$code" != "1" ]; then
  echo "DEBUG upfail stdout:"; cat /tmp/ad-out-upfail.txt
  echo "DEBUG log:"; cat "$LOG" 2>/dev/null || true
fi
rm -rf "$DIR"

# --- revisions divergentes ---
DIR="$(mktemp -d "${TMPDIR:-/tmp}/fala42-ad-XXXXXX")"
setup_case "$DIR"
echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$DIR/stubstate/rev-app"
echo "cccccccccccccccccccccccccccccccccccccccc" >"$DIR/stubstate/rev-worker"
before="$(cat "$DIR/project/docker-compose.tech42.yml")"
set +e
"$SCRIPT" >/tmp/ad-out-rev.txt 2>&1
code=$?
set -e
after="$(cat "$DIR/project/docker-compose.tech42.yml")"
assert_eq "revisions_divergentes.exit" "$code" "0"
assert_eq "revisions_divergentes.compose_igual" "$before" "$after"
assert_file_has "revisions_divergentes.log" "$LOG" "revisions divergentes"
assert_file_not_has "revisions_divergentes.sem_deploy" "$LOG" "DEPLOY OK"
if ! grep -q 'revisions divergentes' "$LOG" 2>/dev/null; then
  echo "DEBUG rev stdout:"; cat /tmp/ad-out-rev.txt
  echo "DEBUG log:"; cat "$LOG" 2>/dev/null || true
fi
rm -rf "$DIR"

echo "== resultado: $PASS pass, $FAIL fail =="
[ "$FAIL" -eq 0 ]
