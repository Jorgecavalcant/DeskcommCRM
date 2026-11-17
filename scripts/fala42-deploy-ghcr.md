# Deploy Fala42 via GHCR

Runbook para aplicar na VPS as imagens `ghcr.io/jorgecavalcant/fala42-app` e `fala42-worker` publicadas pelo workflow `.github/workflows/fala42-ghcr-publish.yml`.

## O que este PR **não** faz

- Não altera `docker-compose.prod.yml` nem qualquer compose versionado aqui.
- O compose real de produção continua em **`/srv/projetos/clientes/fala42/docker-compose.tech42.yml`** (fora do repo).

## Pré-requisitos

- Usuário `jorge` com acesso SSH e membro do grupo `docker` (sem `sudo`).
- `docker` e `docker compose` instalados.
- Login no GHCR na VPS (`docker login ghcr.io`) com token de leitura de pacotes, se as imagens forem privadas.

## Comandos

```bash
# Ajuda
bash scripts/fala42-deploy-ghcr.sh --help

# Simulação (não chama docker de verdade se o compose não existir localmente)
bash scripts/fala42-deploy-ghcr.sh --tag prod --dry-run

# Deploy real na VPS (a partir do diretório do projeto no servidor)
bash scripts/fala42-deploy-ghcr.sh --tag prod
```

O script:

1. Faz `docker pull` das duas imagens com a tag indicada (`prod` ou SHA curto).
2. Salva backup das linhas `image:` atuais em `.deploy-backups/`.
3. Sobe só **app** e **worker** via `docker compose up -d`.
4. Aguarda health; se falhar, tenta rollback para as imagens anteriores.

Se o compose usa variáveis `APP_IMAGE` / `WORKER_IMAGE` no `.env`, exporte-as antes ou ajuste o `.env` na VPS — o script exporta `APP_IMAGE` e `WORKER_IMAGE` para o `docker compose` no momento do `up`.

## Tags publicadas pelo CI

- `prod` — último build do branch `base/prod-1.111.0` (só em push / `workflow_dispatch`)
- SHA curto do commit (7 caracteres)
- Em PR contra `base/prod-1.111.0` o workflow só faz build de validação (`push: false`)