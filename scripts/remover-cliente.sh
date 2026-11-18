#!/usr/bin/env bash
# Apaga um cliente de teste por completo: serviço systemd, DNS, nginx, pasta e
# inventário, num comando só.
#
# Uso: ./remover-cliente.sh --slug <slug> --confirmar [--tenho-certeza --repetir-slug <slug>]
#
# --confirmar é obrigatório — sem ele, só mostra o que seria removido e
# sai sem mexer em nada (dry-run por padrão, ação destrutiva não pode ser
# o comportamento default).
#
# NUNCA rodar isso pra remover a instância real de um cliente pagante.
# Feito pra desfazer cliente de teste. Slugs "protegidos" abaixo pedem
# uma segunda confirmação explícita, de propósito.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/config.sh"   # define PROTEGIDOS, APP_NOME e DOMINIO_BASE

SLUG=""
CONFIRMAR=false
TENHO_CERTEZA=false
REPETIR_SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --confirmar) CONFIRMAR=true; shift ;;
    --tenho-certeza) TENHO_CERTEZA=true; shift ;;
    --repetir-slug) REPETIR_SLUG="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "Uso: $0 --slug <slug> --confirmar" >&2
  exit 1
fi
if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
  echo "Slug inválido: '$SLUG'" >&2
  exit 1
fi

for protegido in "${PROTEGIDOS[@]}"; do
  if [[ "$SLUG" == "$protegido" ]]; then
    if ! $TENHO_CERTEZA; then
      echo "'$SLUG' é um slug protegido (instância de cliente pagante). Se for isso mesmo, adicione --tenho-certeza. Se não tinha certeza, pare agora." >&2
      exit 1
    fi
  fi
done

INFO_JSON="$(python3 "$SCRIPT_DIR/inventario.py" info "$SLUG" 2>/dev/null || true)"
if [[ -n "$INFO_JSON" ]]; then
  SUBDOMINIO="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['subdominio'])" "$INFO_JSON")"
  SERVIDOR="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('servidor','dev'))" "$INFO_JSON")"
  CAMINHO_INVENTARIO="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('path') or '')" "$INFO_JSON")"
else
  CAMINHO_INVENTARIO=""
  SUBDOMINIO="$SLUG.$DOMINIO_BASE"
  # "producao" por padrão (não "dev") porque é o servidor padrão de todo
  # provisionamento novo desde 01/09 — um cliente que falhou ANTES da
  # etapa 11 (registro no inventário) e por isso não aparece aqui tem
  # muito mais chance de ter ficado órfão lá do que na VPS de dev.
  SERVIDOR="producao"
  echo "Aviso: '$SLUG' não está no inventário — seguindo mesmo assim (assumindo subdomínio padrão $SUBDOMINIO e servidor producao, o padrão), pra limpar resíduo de serviço/pasta órfã. Instância órfã em outro servidor precisa de limpeza manual (o servidor dev não recebe provisionamento)." >&2
fi

IFS='|' read -r SSH_ALIAS IP_SERVIDOR < <(python3 "$SCRIPT_DIR/servidores.py" "$SERVIDOR")
remoto() {
  if [[ -z "$SSH_ALIAS" ]]; then
    bash -c "$(cat)"
  else
    ssh "$SSH_ALIAS" bash -s <<< "$(cat)"
  fi
}

# Pasta da instância NO SERVIDOR: o path do inventário, senão a base do
# servidor (nunca a pasta local daqui).
DEST="$(python3 "$SCRIPT_DIR/servidores.py" resolver "$SERVIDOR" "$SLUG" "$CAMINHO_INVENTARIO")" || {
  echo "Erro: não consegui resolver a pasta de '$SLUG' no servidor '$SERVIDOR' — nada foi removido." >&2
  exit 1
}

# Guardas do rm -rf, em servidores.py (checar_remocao, testável): caminho
# canônico, nada raso, nem a base das instâncias nem ancestral dela. Sai 0 se
# a pasta é a padrão <base>/<slug>, 2 se foge do padrão (instância criada fora do
# layout padrão: só com --tenho-certeza), 1 se recusa.
FORA_DO_PADRAO=false
python3 "$SCRIPT_DIR/servidores.py" checar-remocao "$SERVIDOR" "$SLUG" "$DEST" || CODIGO=$?
case "${CODIGO:-0}" in
  0) ;;
  2) FORA_DO_PADRAO=true ;;
  *) echo "Erro: pasta '$DEST' recusada pelas guardas do rm -rf — nada foi removido." >&2; exit 1 ;;
esac
if $FORA_DO_PADRAO && ! $TENHO_CERTEZA; then
  echo "Erro: a pasta de '$SLUG' ($DEST) foge do padrão <base>/<slug> do servidor '$SERVIDOR'. Remover uma instância fora do padrão exige --tenho-certeza (e, pra executar, --repetir-slug $SLUG e o $DB_ARQUIVO guardado antes); se não tinha certeza, pare agora. Nada foi removido." >&2
  exit 1
fi
# Mesmo destino do backup diário: ~/backups/<nome da pasta da instância>, fora
# da árvore que some aqui. É o basename do DEST, igual ao atualizar-cliente.sh
# e ao backup diário, para histórico e cópia final ficarem juntos.
GUARDA_NOME="$(basename "$DEST")"
GUARDA_DIR="\$HOME/backups/$GUARDA_NOME"
CARIMBO="$(date -u +%Y%m%d-%H%M%S)"

echo "=================================================================="
echo "Vai remover '$SLUG' (servidor: $SERVIDOR):"
echo "  - Serviços systemd: $APP_NOME-$SLUG.service (+ backup/sync, se existirem)"
echo "  - DNS: $SUBDOMINIO (API da CDN)"
echo "  - Nginx: vhost de $SLUG"
echo "  - Pasta: $DEST"
echo "  - Registro no inventário"
echo ""
echo "  O banco do cliente é copiado ANTES de qualquer remoção, pra"
echo "  ~/backups/$GUARDA_NOME (fora da pasta apagada). Nada aqui rotaciona essa cópia."
echo "=================================================================="

if ! $CONFIRMAR; then
  echo "Nada foi removido (dry-run) — rode de novo com --confirmar pra executar de verdade."
  if $FORA_DO_PADRAO; then
    echo "Pasta fora do padrão: pra executar, também --tenho-certeza --repetir-slug $SLUG (e o $DB_ARQUIVO precisa existir: ele é guardado antes do rm -rf)."
  fi
  exit 0
fi
if $FORA_DO_PADRAO && [[ "$REPETIR_SLUG" != "$SLUG" ]]; then
  echo "Erro: pasta fora do padrão ($DEST) — digite o slug de novo com --repetir-slug $SLUG pra confirmar. Nada foi removido." >&2
  exit 1
fi

# --- Guardar o banco ANTES de apagar qualquer coisa ---------------------------
# O backup do cliente não pode morar dentro da pasta que este script apaga:
# excluir o cliente apagaria junto a única forma de desfazer.
#
# Este é o PRIMEIRO passo destrutivo, de propósito: se a cópia falhar, nada
# foi removido ainda e a mensagem de erro pode dizer isso sem mentir. Para
# o serviço antes de copiar, pra o banco não estar sendo escrito no meio —
# o bloco do systemd mais abaixo depois desabilita e remove as units.
if ! remoto <<EOF
set -euo pipefail
if [[ ! -f '$DEST/$DB_ARQUIVO' ]]; then
  if $FORA_DO_PADRAO; then
    # Antes do stop: abortar aqui não pode deixar o serviço parado.
    echo "Erro: '$DEST/$DB_ARQUIVO' não existe e a pasta está fora do padrão — sem banco guardado não removo." >&2
    exit 1
  fi
  systemctl --user stop '$APP_NOME-$SLUG.service' 2>/dev/null || true
  echo "Aviso: '$DEST/$DB_ARQUIVO' não existe — nada a guardar." >&2
  exit 0
fi
systemctl --user stop '$APP_NOME-$SLUG.service' 2>/dev/null || true
mkdir -p "$GUARDA_DIR"
chmod 700 "$GUARDA_DIR"
cp '$DEST/$DB_ARQUIVO' "$GUARDA_DIR/excluido-$CARIMBO.db"
chmod 600 "$GUARDA_DIR/excluido-$CARIMBO.db"
# Histórico que ainda estiver no lugar antigo vai junto — ele some com a
# pasta daqui a pouco.
if [[ -d '$DEST/backups' ]]; then
  for f in '$DEST/backups/'*.db; do
    [[ -e "\$f" ]] || continue
    cp -n "\$f" "$GUARDA_DIR/" || true
    chmod 600 "$GUARDA_DIR/\$(basename "\$f")" 2>/dev/null || true
  done
fi
EOF
then
  echo "Erro: falha ao guardar o banco de '$SLUG' em ~/backups/$GUARDA_NOME — NADA foi removido. Resolva isso antes de tentar de novo." >&2
  exit 1
fi
echo "==> Banco guardado em ~/backups/$GUARDA_NOME/excluido-$CARIMBO.db"

# --- Systemd (no servidor onde o cliente roda) --------------------------------
remoto <<EOF
SYSTEMD_USER_DIR="\$HOME/.config/systemd/user"
for arquivo in "$APP_NOME-$SLUG.service" "$APP_NOME-$SLUG-backup.service" "$APP_NOME-$SLUG-backup.timer" "$APP_NOME-$SLUG-sync.service" "$APP_NOME-$SLUG-sync.timer"; do
  if [[ -f "\$SYSTEMD_USER_DIR/\$arquivo" ]]; then
    systemctl --user disable --now "\$arquivo" 2>/dev/null || true
    rm -f "\$SYSTEMD_USER_DIR/\$arquivo"
    echo "==> Removido: \$arquivo"
  fi
done
systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
EOF


# --- DNS -----------------------------------------------------------------
if python3 "$SCRIPT_DIR/criar-dns.py" remover "$SUBDOMINIO"; then
  echo "==> DNS removido (ou já não existia)"
else
  echo "Aviso: falha ao remover DNS de '$SUBDOMINIO' — conferir manualmente na CDN." >&2
fi

# --- Nginx (no servidor onde o cliente roda) ----------------------------------
if [[ -z "$SSH_ALIAS" ]]; then
  NGINX_REMOVIDO=false
  sudo -n "$SCRIPT_DIR/aplicar-nginx.sh" remover "$SLUG" && NGINX_REMOVIDO=true
else
  # mesmo script já deve ter sido enviado no provisionamento — reenvia por
  # garantia (idempotente) antes de rodar.
  NGINX_REMOVIDO=false
  ssh "$SSH_ALIAS" "mkdir -p ~/provisionamento-remoto/scripts"
  scp -q "$SCRIPT_DIR/aplicar-nginx.sh" "$SSH_ALIAS:~/provisionamento-remoto/scripts/"
  ssh "$SSH_ALIAS" "chmod +x ~/provisionamento-remoto/scripts/aplicar-nginx.sh && sudo ~/provisionamento-remoto/scripts/aplicar-nginx.sh remover '$SLUG'" && NGINX_REMOVIDO=true
fi
if $NGINX_REMOVIDO; then
  echo "==> Nginx removido (ou já não existia)"
else
  echo "Aviso: falha ao remover Nginx de '$SLUG' (sudoers/acesso configurado? ver README, "Sudoers restrito") — conferir manualmente." >&2
fi

# --- Pasta (no servidor onde o cliente roda) ----------------------------------
remoto <<EOF
if [[ -d '$DEST' ]]; then
  rm -rf '$DEST'
  echo "==> Pasta removida: $DEST"
fi
EOF

# --- Inventário -----------------------------------------------------------------
if python3 "$SCRIPT_DIR/inventario.py" remover "$SLUG"; then
  echo "==> Removido do inventário"
else
  echo "Aviso: '$SLUG' não estava no inventário (ok se já sabia disso)." >&2
fi
python3 "$SCRIPT_DIR/gerar-targets-prometheus.py"
echo "==> Alvo do Prometheus atualizado"

# --- Status de provisionamento ----------------------------------------------
# Guarda a senha temporária do admin em texto puro (achado 26/08, revisão de
# segurança) — não faz sentido esse resíduo sobreviver ao cliente que ele
# descreve.
STATUS_ARQUIVO="$RAIZ/status/$SLUG.json"
if [[ -f "$STATUS_ARQUIVO" ]]; then
  rm -f "$STATUS_ARQUIVO"
  echo "==> Status de provisionamento removido"
fi

echo ""
echo "Cliente '$SLUG' removido."
