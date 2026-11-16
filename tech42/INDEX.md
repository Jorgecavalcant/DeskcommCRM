# Fala42 — índice overlay Tech42

Pasta: `/srv/projetos/clientes/fala42/tech42/`  
Produto: **Fala42** (DeskcommCRM self-hosted)  
URL pública: https://fala42.tech42.com.br  
Alias legado: https://deskcomm.jcplanejamento.com.br  
SSH: `fiadopro-vps`  
Compose project name: `deskcommcrm` (containers `deskcommcrm-*`)

## Scripts
- `install-tech42.sh` — instalação isolada (seed `APP_NAME=Fala42`, DOMAIN default fala42)
- `rollback-tech42.sh` — down só deste stack (sem `-v`)
- `bootstrap-admin.sh` / `fix-baseline.sh`

## LOGs locais
- LOG_058 — seed dados teste
- LOG_059 — Meta WhatsApp Cloud
- LOG_060 — sync OpenRouter catalog
- Ver também: `/srv/infraestrutura/documentacao/logs/LOG_062_FALA42_RENOMEAR_MOVER_20261116.md`
