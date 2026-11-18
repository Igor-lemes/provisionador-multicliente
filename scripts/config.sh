# Configuração do app que está sendo provisionado. Carregado (source) pelos
# scripts. Tudo pode ser sobrescrito por variável de ambiente.
#
# Este projeto não conhece o app: ele só sabe copiar uma fonte git, instalar,
# migrar, compilar e subir como serviço systemd atrás do nginx. Os comandos
# abaixo são o contrato.

# Repositório git local com a fonte do app (só o que está COMMITADO é copiado).
APP_REPO="${APP_REPO:-$HOME/projetos/app}"
# Nome do app (usado em nomes de unit: app-<slug>.service).
APP_NOME="${APP_NOME:-app}"
# Domínio-base: cada cliente vira <slug>.$DOMINIO_BASE
DOMINIO_BASE="${DOMINIO_BASE:-exemplo.com}"
# Rota de saúde (HTTP 200 = no ar).
SAUDE_PATH="${SAUDE_PATH:-/health}"
# Comandos executados DENTRO da pasta da instância, no servidor alvo.
APP_INSTALL_CMD="${APP_INSTALL_CMD:-npm ci}"
APP_MIGRATE_CMD="${APP_MIGRATE_CMD:-npm run migrate}"
APP_BUILD_CMD="${APP_BUILD_CMD:-npm run build}"
# Comando de start (vai para o ExecStart; use caminho absoluto do binário).
APP_START_CMD="${APP_START_CMD:-/usr/bin/node server.js}"
# Binário do Node usado nos serviços (fixado para o build e o serviço usarem a
# mesma ABI; ver README, decisão 6).
NODE_BIN_DIR="${NODE_BIN_DIR:-/home/deploy/.nvm/versions/node/v24.0.0/bin}"
# Slugs que exigem --tenho-certeza para qualquer ação destrutiva/de deploy.
PROTEGIDOS=(${PROTEGIDOS:-cliente-a})
# Arquivo do banco (SQLite) dentro da pasta da instância.
DB_ARQUIVO="${DB_ARQUIVO:-app.db}"
# Pastas versionadas comparadas na checagem de arquivos órfãos pós-atualização.
ORFAOS_DIRS="${ORFAOS_DIRS:-src scripts public}"
