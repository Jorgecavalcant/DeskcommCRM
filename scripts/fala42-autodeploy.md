# Autodeploy Fala42 (cron na VPS)

Aplica sozinho as imagens públicas do GHCR quando o Jorge faz merge em `base/prod-1.111.0` e o workflow publica a tag `prod`.

## O que faz

A cada 5 minutos o cron do usuário `jorge` roda `fala42-autodeploy.sh`:

1. Consulta o digest remoto da tag `prod` (app e worker) **sem baixar** a imagem.
2. Se for o mesmo digest já aplicado → sai quieto.
3. Se for digest marcado como ruim → não tenta de novo.
4. Se houver espaço em disco, puxa as imagens por digest, confere se app e worker têm a **mesma** revision (senão espera o próximo ciclo — CI ainda publicando um deles).
5. Faz backup do `docker-compose.tech42.yml` + `docker inspect`, atualiza só as linhas `image:` de app/worker, sobe **somente** esses dois serviços (`up -d --no-deps`).
6. Espera health (containers + `/api/v1/health`). Se falhar → restaura o compose, sobe de novo e grava o digest em `digests-ruins`.

Nunca roda `down`, nunca `prune`, nunca mexe em redis/waha/caddy/etc. Nunca imprime `.env`.

## Instalar (usuário jorge, sem sudo)

```bash
mkdir -p ~/bin
cp /caminho/do/repo/scripts/fala42-autodeploy.sh ~/bin/
chmod +x ~/bin/fala42-autodeploy.sh

# Crontab do jorge (crontab -e):
*/5 * * * * /home/jorge/bin/fala42-autodeploy.sh >/dev/null 2>&1
```

O script escreve o log em:

`/srv/projetos/clientes/fala42/tech42/autodeploy/autodeploy.log`

## Pausar / retomar

```bash
# Pausar (o cron continua, mas o script sai na hora)
touch /srv/projetos/clientes/fala42/tech42/autodeploy/PAUSADO

# Retomar
rm -f /srv/projetos/clientes/fala42/tech42/autodeploy/PAUSADO
```

## Ver status e log

```bash
/home/jorge/bin/fala42-autodeploy.sh --status
tail -n 50 /srv/projetos/clientes/fala42/tech42/autodeploy/autodeploy.log
```

## Dry-run

```bash
/home/jorge/bin/fala42-autodeploy.sh --dry-run
```

## Rollback manual

1. Olhe o backup mais recente em `…/tech42/autodeploy/backups/<timestamp>/`.
2. Copie o `docker-compose.tech42.yml` de volta para o projeto.
3. Suba só app e worker:

```bash
cd /srv/projetos/clientes/fala42
docker compose --env-file .env \
  -f docker-compose.prod.yml \
  -f docker-compose.single-server.yml \
  -f docker-compose.tech42.yml \
  up -d --no-deps app worker
```

As imagens anteriores também ficam tagueadas como `fala42-rollback:app-auto-anterior` e `fala42-rollback:worker-auto-anterior` no último ciclo.

## Primeiro uso (bootstrap)

Na primeira execução, se `ultimo-digest-app` / `ultimo-digest-worker` ainda não existirem e os containers já estiverem na **mesma** revision que a tag `prod` remota, o script **só grava os digests** e sai — sem redeploy. Assim o cron não “atualiza” à toa no dia da instalação.

## Variáveis úteis

| Variável | Default |
|---|---|
| `PROJECT_DIR` | `/srv/projetos/clientes/fala42` |
| `STATE_DIR` | `$PROJECT_DIR/tech42/autodeploy` |
| `HEALTH_URL` | `http://127.0.0.1:10028/api/v1/health` |
| `MIN_FREE_GB` | `3` |
| `APP_CONTAINER` | `deskcommcrm-app-1` |
| `WORKER_CONTAINER` | `deskcommcrm-worker-1` |
