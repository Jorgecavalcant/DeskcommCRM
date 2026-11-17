---
impacto: capacidade_nova
secao: adicionado
titulo: Build automático das imagens Fala42 no GHCR
---

Depois de mesclar e habilitar o workflow no fork, cada push na branch
`base/prod-1.111.0` publica `ghcr.io/jorgecavalcant/fala42-app` e
`fala42-worker` (tags `prod` e SHA curto). PRs contra essa base fazem
build de validação (dry-run, sem push). O compose de produção na VPS
não muda sozinho — use `scripts/fala42-deploy-ghcr.sh` quando for atualizar.