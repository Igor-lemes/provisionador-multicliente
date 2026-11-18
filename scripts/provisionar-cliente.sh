#!/usr/bin/env bash
# Provisiona uma instância nova do app para um cliente. Idempotente: recusa
# rodar se o slug já existe.
#
# Uso:
#   ./provisionar-cliente.sh --slug cliente-c --nome "Cliente C" \
#     --features crm,agenda [--porta 8081] [--servidor producao|dev] [--status-arquivo f.json]
#
# --servidor escolhe em qual máquina a instância roda (ver servidores.py). Todo
# o resto do script é idêntico nos dois casos; só a EXECUÇÃO dos comandos muda
# (local vs. via SSH), pela função `remoto`.
#
# --porta é opcional: auto-aloca a próxima livre a partir de 8081, checando a
# porta NO SERVIDOR escolhido.
# --status-arquivo: onde escrever o progresso (etapa atual) em JSON, para uma
# API de controle acompanhar por polling. Opcional.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/fixar-node.sh"
TEMPLATES_DIR="$RAIZ/templates"

SLUG=""; NOME_NEGOCIO=""; FEATURES=""; PORTA=""; STATUS_ARQUIVO=""; SERVIDOR="producao"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --nome) NOME_NEGOCIO="$2"; shift 2 ;;
    --features) FEATURES="$2"; shift 2 ;;
    --porta) PORTA="$2"; shift 2 ;;
    --status-arquivo) STATUS_ARQUIVO="$2"; shift 2 ;;
    --servidor) SERVIDOR="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SLUG" || -z "$NOME_NEGOCIO" || -z "$FEATURES" ]]; then
  echo "Uso: $0 --slug <slug> --nome \"<Nome>\" --features <f1,f2,...> [--porta N] [--servidor producao|dev]" >&2
  exit 1
fi
# O slug vira caminho de pasta e nome de unit systemd dentro de heredoc.
if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
  echo "Slug inválido: '$SLUG' — só minúsculo, número e hífen (ex: cliente-a)." >&2
  exit 1
fi
# O nome também entra no .env, no Description= das units e nos templates. A
# regra mora em validacao.py para ser UMA só entre a CLI e uma API de controle.
python3 "$SCRIPT_DIR/validacao.py" nome "$NOME_NEGOCIO" || exit 1

# --- Servidor alvo (dev = local, producao = via SSH) --------------------------
IFS='|' read -r SSH_ALIAS IP_SERVIDOR < <(python3 "$SCRIPT_DIR/servidores.py" "$SERVIDOR")

# Executa um script bash (via stdin) local ou no servidor remoto, sempre com o
# Node certo no PATH. Uso: `remoto <<'EOF' ... EOF`.
remoto() {
  local script
  script="export PATH=\"$NODE_BIN_DIR:\$PATH\"
$(cat)"
  if [[ -z "$SSH_ALIAS" ]]; then bash -c "$script"; else ssh "$SSH_ALIAS" bash -s <<< "$script"; fi
}

# --- Progresso ----------------------------------------------------------------
TOTAL_ETAPAS=11
ETAPA_ATUAL=0
etapa() {
  ETAPA_ATUAL="$1"
  echo "==> [$ETAPA_ATUAL/$TOTAL_ETAPAS] $2"
  if [[ -n "$STATUS_ARQUIVO" ]]; then
    python3 "$SCRIPT_DIR/escrever-status.py" "$STATUS_ARQUIVO" "$ETAPA_ATUAL" "$TOTAL_ETAPAS" "$2" "$3" rodando
  fi
}

# Um trap EXIT só: limpa temporários e marca o status final, sucesso ou falha.
ENV_LOCAL=""; ENV_SYSTEMD_LOCAL=""; UNIT_TMP_DIR=""
finalizar() {
  local codigo=$?
  rm -f "$ENV_LOCAL" "$ENV_SYSTEMD_LOCAL"; [[ -n "$UNIT_TMP_DIR" ]] && rm -rf "$UNIT_TMP_DIR"
  if [[ -n "$STATUS_ARQUIVO" ]]; then
    if [[ $codigo -eq 0 ]]; then
      python3 "$SCRIPT_DIR/escrever-status.py" "$STATUS_ARQUIVO" "$TOTAL_ETAPAS" "$TOTAL_ETAPAS" "Concluído" "" ok
    else
      python3 "$SCRIPT_DIR/escrever-status.py" "$STATUS_ARQUIVO" "$ETAPA_ATUAL" "$TOTAL_ETAPAS" "Falhou" "" erro
    fi
  fi
}
trap finalizar EXIT

CLIENTES_DIR="$(python3 "$SCRIPT_DIR/servidores.py" clientes-dir "$SERVIDOR")" || {
  echo "Erro: o servidor '$SERVIDOR' não recebe provisionamento." >&2; exit 1; }
DEST="$(python3 "$SCRIPT_DIR/servidores.py" resolver "$SERVIDOR" "$SLUG")"

# --- Idempotência -------------------------------------------------------------
if remoto <<< "[[ -d '$DEST' ]]"; then
  echo "Erro: $DEST já existe no servidor '$SERVIDOR'. Apague a pasta ou escolha outro slug." >&2; exit 1
fi
if python3 "$SCRIPT_DIR/inventario.py" existe "$SLUG"; then
  echo "Erro: '$SLUG' já está no inventário, mesmo sem a pasta. Investigar antes de continuar." >&2; exit 1
fi

# --- Porta (checada NO SERVIDOR alvo) -----------------------------------------
porta_livre() { ! remoto <<< "ss -ltn 2>/dev/null | grep -q ':$1 '"; }
if [[ -z "$PORTA" ]]; then
  PORTA=8081; while ! porta_livre "$PORTA"; do PORTA=$((PORTA + 1)); done
elif ! porta_livre "$PORTA"; then
  echo "Erro: porta $PORTA já está em uso no servidor '$SERVIDOR'." >&2; exit 1
fi

SUBDOMINIO="$SLUG.$DOMINIO_BASE"
echo "==> Provisionando '$SLUG' ($NOME_NEGOCIO) em '$SERVIDOR', porta $PORTA, features: $FEATURES"

# --- 1. Copiar a fonte (só o que está no git: nunca .env, banco, node_modules) -
etapa 1 "Copiando a fonte do app" "checar-fonte.sh + git archive HEAD | tar -x"
"$SCRIPT_DIR/checar-fonte.sh" "$APP_REPO" "$APP_NOME"
remoto <<< "mkdir -p '$CLIENTES_DIR' '$DEST'"
if [[ -z "$SSH_ALIAS" ]]; then
  git -C "$APP_REPO" archive HEAD | tar -x -C "$DEST"
else
  git -C "$APP_REPO" archive HEAD | ssh "$SSH_ALIAS" "tar -x -C '$DEST'"
fi
# Marca em que commit a instância nasceu: é a base de comparação que o
# atualizar-cliente.sh usa para perguntar ao git quais arquivos saíram do repo.
remoto <<< "printf '%s' '$(git -C "$APP_REPO" rev-parse --short HEAD)' > '$DEST/.commit-implantado'"

# --- 2. .env a partir do template (sempre local; é só texto) -------------------
etapa 2 "Gerando configuração (.env)" "openssl rand + preencher-template.py"
# Os VALORES vão por ambiente, não por argv: argumento de processo é legível por
# qualquer usuário da máquina via `ps`, e aqui passam os segredos da instância.
export AUTH_SECRET CRON_SECRET SUBDOMINIO NOME_NEGOCIO FEATURES_ENABLED
AUTH_SECRET=$(openssl rand -base64 32)
CRON_SECRET=$(openssl rand -base64 32)
FEATURES_ENABLED="$FEATURES"
ENV_LOCAL="$(mktemp)"
# Substituição literal em Python, nunca sed: valor com "|" fecharia a expressão
# do sed e viraria programa (a flag `e` do s/// executa shell).
python3 "$SCRIPT_DIR/preencher-template.py" "$TEMPLATES_DIR/env.template" "$ENV_LOCAL" \
  AUTH_SECRET CRON_SECRET SUBDOMINIO FEATURES_ENABLED NOME_NEGOCIO

# --- 3. .env.systemd (cópia sem variável com "$" no valor) ---------------------
etapa 3 "Gerando .env.systemd" "gerar-env-systemd.py"
ENV_SYSTEMD_LOCAL="$(mktemp)"
python3 "$SCRIPT_DIR/gerar-env-systemd.py" "$ENV_LOCAL" "$ENV_SYSTEMD_LOCAL"
if [[ -z "$SSH_ALIAS" ]]; then
  cp "$ENV_LOCAL" "$DEST/.env"; cp "$ENV_SYSTEMD_LOCAL" "$DEST/.env.systemd"
else
  scp -q "$ENV_LOCAL" "$SSH_ALIAS:$DEST/.env"; scp -q "$ENV_SYSTEMD_LOCAL" "$SSH_ALIAS:$DEST/.env.systemd"
fi
rm -f "$ENV_LOCAL" "$ENV_SYSTEMD_LOCAL"; ENV_LOCAL=""; ENV_SYSTEMD_LOCAL=""

# --- 4-6. Instalar, migrar, compilar -------------------------------------------
etapa 4 "Instalando dependências" "$APP_INSTALL_CMD"
remoto <<EOF
set -e
cd '$DEST'
$APP_INSTALL_CMD
EOF
etapa 5 "Aplicando migrações do banco" "$APP_MIGRATE_CMD"
remoto <<EOF
set -e
cd '$DEST'
$APP_MIGRATE_CMD
EOF
etapa 6 "Compilando a aplicação" "$APP_BUILD_CMD"
remoto <<EOF
set -e
cd '$DEST'
$APP_BUILD_CMD
EOF

# --- 7. Units systemd a partir dos templates -----------------------------------
etapa 7 "Configurando serviços (systemd --user)" "systemctl --user enable --now"
export SLUG PORTA APP_NOME WORKDIR="$DEST" START_CMD="$APP_START_CMD" CRON_PATH="${CRON_PATH:-/api/cron}" \
       BACKUP_CMD="${BACKUP_CMD:-$NODE_BIN_DIR/node scripts/backup-db.js}"
UNIT_TMP_DIR="$(mktemp -d)"
gerar_unit() {
  python3 "$SCRIPT_DIR/preencher-template.py" "$TEMPLATES_DIR/$1" "$UNIT_TMP_DIR/$2" \
    SLUG NOME_NEGOCIO PORTA APP_NOME WORKDIR START_CMD BACKUP_CMD CRON_PATH
}
gerar_unit app.service.template     "$APP_NOME-$SLUG.service"
gerar_unit backup.service.template  "$APP_NOME-$SLUG-backup.service"
gerar_unit backup.timer.template    "$APP_NOME-$SLUG-backup.timer"
gerar_unit sync.service.template    "$APP_NOME-$SLUG-sync.service"
gerar_unit sync.timer.template      "$APP_NOME-$SLUG-sync.timer"
if [[ -z "$SSH_ALIAS" ]]; then
  mkdir -p "$HOME/.config/systemd/user"; cp "$UNIT_TMP_DIR"/* "$HOME/.config/systemd/user/"
else
  ssh "$SSH_ALIAS" "mkdir -p ~/.config/systemd/user"; scp -q "$UNIT_TMP_DIR"/* "$SSH_ALIAS:~/.config/systemd/user/"
fi
rm -rf "$UNIT_TMP_DIR"; UNIT_TMP_DIR=""
remoto <<EOF
set -e
systemctl --user daemon-reload
systemctl --user enable --now '$APP_NOME-$SLUG.service'
systemctl --user enable --now '$APP_NOME-$SLUG-backup.timer'
systemctl --user enable --now '$APP_NOME-$SLUG-sync.timer'
EOF

# --- 8. Inventário e alvos do Prometheus ---------------------------------------
etapa 8 "Registrando no inventário" "inventario.py adicionar"
python3 "$SCRIPT_DIR/inventario.py" adicionar "$SLUG" "$NOME_NEGOCIO" "$SUBDOMINIO" "$PORTA" "$DEST" "$FEATURES" "$SERVIDOR"
python3 "$SCRIPT_DIR/gerar-targets-prometheus.py"

# --- 9. Healthcheck ------------------------------------------------------------
etapa 9 "Verificando saúde da instância" "curl localhost:$PORTA$SAUDE_PATH"
OK=false
for _ in $(seq 1 15); do
  if remoto <<< "curl -sf 'http://localhost:$PORTA$SAUDE_PATH' -o /dev/null"; then OK=true; break; fi
  sleep 1
done
if ! $OK; then
  python3 "$SCRIPT_DIR/inventario.py" status "$SLUG" erro
  echo "Aviso: '$SLUG' não respondeu em http://localhost:$PORTA$SAUDE_PATH — status 'erro' no inventário. Ver: ssh ${SSH_ALIAS:-local} journalctl --user -u $APP_NOME-$SLUG.service" >&2
fi

# --- 10-11. nginx e DNS (só se a instância local já respondeu) -------------------
# Não faz sentido apontar o DNS para um serviço que nem subiu direito.
DNS_OK=false
etapa 10 "Configurando proxy (nginx)" "aplicar-nginx.sh criar"
NGINX_OK=false
if $OK; then
  if [[ -z "$SSH_ALIAS" ]]; then
    sudo -n "$SCRIPT_DIR/aplicar-nginx.sh" criar "$SLUG" "$SUBDOMINIO" "$PORTA" && NGINX_OK=true
  else
    # aplicar-nginx.sh procura o template em "$SCRIPT_DIR/../templates": replica
    # o mesmo layout relativo no destino.
    ssh "$SSH_ALIAS" "mkdir -p ~/provisionamento-remoto/scripts ~/provisionamento-remoto/templates"
    scp -q "$SCRIPT_DIR/aplicar-nginx.sh" "$SSH_ALIAS:~/provisionamento-remoto/scripts/"
    scp -q "$TEMPLATES_DIR/nginx.conf.template" "$SSH_ALIAS:~/provisionamento-remoto/templates/"
    ssh "$SSH_ALIAS" "chmod +x ~/provisionamento-remoto/scripts/aplicar-nginx.sh && sudo ~/provisionamento-remoto/scripts/aplicar-nginx.sh criar '$SLUG' '$SUBDOMINIO' '$PORTA'" && NGINX_OK=true
  fi
fi
etapa 11 "Configurando DNS" "criar-dns.py criar"
if $NGINX_OK && python3 "$SCRIPT_DIR/criar-dns.py" criar "$SUBDOMINIO" "$IP_SERVIDOR"; then
  DNS_OK=true
else
  echo "Aviso: falha no nginx/DNS de '$SLUG'. A instância local está OK, mas https://$SUBDOMINIO ainda não responde." >&2
fi

echo
echo "=================================================================="
echo "Cliente '$SLUG' provisionado no servidor '$SERVIDOR'."
echo "  Porta: $PORTA"
if $DNS_OK; then echo "  URL: https://$SUBDOMINIO"; else echo "  URL (configurar DNS/proxy manualmente): $SUBDOMINIO"; fi
echo "=================================================================="
