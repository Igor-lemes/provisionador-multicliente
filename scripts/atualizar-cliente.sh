#!/usr/bin/env bash
# Atualiza um cliente JÁ PROVISIONADO com o código mais recente do app.
# provisionar-cliente.sh só lê o repositório do app na hora de CRIAR o cliente;
# depois disso ele fica congelado no código de quando nasceu. Este script é o
# jeito automatizado de atualizar.
#
# Uso: ./atualizar-cliente.sh <slug> [--tenho-certeza] [--status-arquivo <arquivo>]
#
# Passos: backup do banco, sincroniza código (git archive: nunca toca
# .env/banco/uploads, que não são versionados), instala, migra, compila,
# reinicia e confere a rota de saúde.
#
# Limitação conhecida: sem rollback automático. Só o backup do banco, para
# recuperação manual se algo der muito errado depois do restart.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/fixar-node.sh"

SLUG="${1:-}"
shift || true

TENHO_CERTEZA=""
STATUS_ARQUIVO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenho-certeza) TENHO_CERTEZA="--tenho-certeza"; shift ;;
    --status-arquivo) STATUS_ARQUIVO="$2"; shift 2 ;;
    *) echo "Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "Uso: $0 <slug> [--tenho-certeza] [--status-arquivo <arquivo>]" >&2
  exit 1
fi
# Mesma checagem dos outros scripts: o slug vira caminho de pasta e nome de
# unit systemd dentro de heredoc.
if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
  echo "Slug inválido: '$SLUG' — só minúsculo, número e hífen (ex: cliente-a)." >&2
  exit 1
fi

for protegido in "${PROTEGIDOS[@]}"; do
  if [[ "$SLUG" == "$protegido" && "$TENHO_CERTEZA" != "--tenho-certeza" ]]; then
    echo "'$SLUG' é um slug protegido (cliente em produção). Atualizar código exige --tenho-certeza explícito na CLI." >&2
    exit 1
  fi
done

if ! python3 "$SCRIPT_DIR/inventario.py" existe "$SLUG"; then
  echo "Erro: slug '$SLUG' não existe no inventário." >&2
  exit 1
fi

INFO="$(python3 "$SCRIPT_DIR/inventario.py" info "$SLUG")"
PORTA="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['porta'])" "$INFO")"
SERVIDOR="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('servidor','dev'))" "$INFO")"
DEST="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$INFO")"
IFS='|' read -r SSH_ALIAS IP_SERVIDOR < <(python3 "$SCRIPT_DIR/servidores.py" "$SERVIDOR")

remoto() {
  local script
  script="export PATH=\"$NODE_BIN_DIR:\$PATH\"
$(cat)"
  if [[ -z "$SSH_ALIAS" ]]; then
    bash -c "$script"
  else
    ssh "$SSH_ALIAS" bash -s <<< "$script"
  fi
}

# --- Progresso (mesmo padrão de provisionar-cliente.sh) -----------------
TOTAL_ETAPAS=6
ETAPA_ATUAL=0

etapa() {
  ETAPA_ATUAL="$1"
  local descricao="$2" comando="$3"
  echo "==> [$ETAPA_ATUAL/$TOTAL_ETAPAS] $descricao"
  if [[ -n "$STATUS_ARQUIVO" ]]; then
    python3 "$SCRIPT_DIR/escrever-status.py" "$STATUS_ARQUIVO" "$ETAPA_ATUAL" "$TOTAL_ETAPAS" "$descricao" "$comando" rodando
  fi
}

finalizar_status() {
  local codigo=$?
  if [[ -n "$STATUS_ARQUIVO" ]]; then
    if [[ $codigo -eq 0 ]]; then
      python3 "$SCRIPT_DIR/escrever-status.py" "$STATUS_ARQUIVO" "$TOTAL_ETAPAS" "$TOTAL_ETAPAS" "Concluído" "" ok
    else
      python3 "$SCRIPT_DIR/escrever-status.py" "$STATUS_ARQUIVO" "$ETAPA_ATUAL" "$TOTAL_ETAPAS" "Falhou" "" erro
    fi
  fi
}
trap finalizar_status EXIT

if ! remoto <<< "[[ -d '$DEST' && -f '$DEST/.env' ]]"; then
  echo "Erro: $DEST não existe (ou sem .env) no servidor '$SERVIDOR' — inventário e disco dessincronizados." >&2
  exit 1
fi

# Mesma razão do provisionar-cliente.sh: o código que vai pro cliente sai do
# disco desta VPS, e mergear no GitHub não mexe nele. Confere antes de decidir
# qual é o "commit alvo", senão atualizar cliente pode LEVAR código velho.
"$SCRIPT_DIR/checar-fonte.sh" "$APP_REPO" "$APP_NOME"

COMMIT_ALVO="$(git -C "$APP_REPO" rev-parse --short HEAD)"

# Ref fixada por cliente. Vazia = segue o HEAD, que é o comportamento de sempre.
# Preenchida, só sobe se o HEAD for essa ref. "A gente lembra de trocar a
# branch" não é controle: bastava rodar este script com o checkout errado para
# o cliente receber uma versão ainda não aprovada, em silêncio.
#
# Compara por COMMIT, não por nome de branch: o checkout pode estar em
# detached HEAD, ou numa branch diferente apontando para o mesmo commit. O que
# importa é o que vai subir.
REF_FIXADA="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('ref_deploy') or '')" "$INFO")"
if [[ -n "$REF_FIXADA" ]]; then
  COMMIT_FIXADO="$(git -C "$APP_REPO" rev-parse --short "$REF_FIXADA" 2>/dev/null || true)"
  if [[ -z "$COMMIT_FIXADO" ]]; then
    echo "Erro: '$SLUG' está preso na ref '$REF_FIXADA', que não existe no app. Nada foi feito." >&2
    exit 1
  fi
  if [[ "$COMMIT_ALVO" != "$COMMIT_FIXADO" ]]; then
    echo "Erro: '$SLUG' só recebe a ref '$REF_FIXADA' ($COMMIT_FIXADO), e o app está em $COMMIT_ALVO." >&2
    echo "       Nada foi feito. Pra subir outra coisa, solte a trava de propósito:" >&2
    echo "         python3 $SCRIPT_DIR/inventario.py definir-ref $SLUG --ref \"\"" >&2
    exit 1
  fi
fi

# Em que commit esta instância está. Gravado no fim de cada atualização bem
# sucedida: permite perguntar ao git, e não ao diretório, quais arquivos saíram
# do repositório desde então. Vazio em instância que nunca foi atualizada
# depois desta mudança; nesse caso nada é removido (sem base de comparação, o
# certo é não apagar).
COMMIT_ANTERIOR="$(remoto <<< "cat '$DEST/.commit-implantado' 2>/dev/null || true" | tr -d '[:space:]')"

echo "==> Atualizando '$SLUG' (servidor: $SERVIDOR, path: $DEST) para o commit $COMMIT_ALVO do app"
if [[ -n "$COMMIT_ANTERIOR" ]]; then
  echo "    (estava em $COMMIT_ANTERIOR)"
fi

# O backup de pré-deploy vai para a MESMA pasta do backup diário
# (~/backups/<pasta da instância>), fora da árvore que some quando o cliente é
# removido. O nome é o basename de $DEST de propósito: se divergir do que o
# backup diário usa, a rotação por família deixa de enxergar metade dos
# arquivos. $HOME vai escapado porque quem expande é o shell REMOTO.
PASTA_BACKUP="backups/$(basename "$DEST")"
etapa 1 "Backup do banco antes de qualquer coisa" "cp $DB_ARQUIVO ~/$PASTA_BACKUP/"
remoto <<EOF
set -e
cd '$DEST'
mkdir -p "\$HOME/$PASTA_BACKUP"
chmod 700 "\$HOME/$PASTA_BACKUP"
CARIMBO=\$(date -u +%Y%m%d-%H%M%S)
cp $DB_ARQUIVO "\$HOME/$PASTA_BACKUP/manual-pre-atualizacao-\$CARIMBO.db"
chmod 600 "\$HOME/$PASTA_BACKUP/manual-pre-atualizacao-\$CARIMBO.db"
EOF

etapa 2 "Sincronizando código" "git archive HEAD | tar -x"
if [[ -z "$SSH_ALIAS" ]]; then
  git -C "$APP_REPO" archive HEAD | tar -x -C "$DEST"
else
  git -C "$APP_REPO" archive HEAD | ssh "$SSH_ALIAS" "tar -x -C '$DEST'"
fi

# `git archive | tar -x` só acrescenta e sobrescreve, nunca apaga. Sem este
# passo, arquivo removido do repo fica vivo na instância para sempre. A lista
# vem do GIT, nunca de varredura de diretório: `rsync --delete` levaria junto
# `.env`, o banco, `node_modules/` e os uploads do cliente. Ver
# arquivos-removidos.py.
if [[ -n "$COMMIT_ANTERIOR" ]]; then
  REMOVIDOS="$(python3 "$SCRIPT_DIR/arquivos-removidos.py" "$APP_REPO" "$COMMIT_ANTERIOR" "$COMMIT_ALVO" || true)"
  if [[ -n "$REMOVIDOS" ]]; then
    QUANTOS="$(printf '%s\n' "$REMOVIDOS" | grep -c . || true)"
    echo "==> Removendo $QUANTOS arquivo(s) que saíram do repo desde $COMMIT_ANTERIOR:"
    printf '%s\n' "$REMOVIDOS" | sed 's/^/      /'
    remoto <<EOF
set -e
cd '$DEST'
while IFS= read -r arquivo; do
  [ -n "\$arquivo" ] || continue
  rm -f -- "\$arquivo"
done <<'LISTA'
$REMOVIDOS
LISTA
EOF
  fi
fi

etapa 3 "Instalando dependências" "$APP_INSTALL_CMD"
remoto <<EOF
set -e
cd '$DEST'
$APP_INSTALL_CMD
EOF

etapa 4 "Aplicando migrações do banco" "$APP_MIGRATE_CMD"
remoto <<EOF
set -e
cd '$DEST'
$APP_MIGRATE_CMD
EOF

etapa 5 "Compilando" "$APP_BUILD_CMD"
remoto <<EOF
set -e
cd '$DEST'
$APP_BUILD_CMD
EOF

etapa 6 "Reiniciando serviço e checando saúde" "systemctl --user restart + curl $SAUDE_PATH"
remoto <<EOF
set -e
systemctl --user restart '$APP_NOME-$SLUG.service'
EOF

OK=false
for _ in $(seq 1 15); do
  if remoto <<< "curl -sf 'http://localhost:$PORTA$SAUDE_PATH' -o /dev/null"; then
    OK=true
    break
  fi
  sleep 1
done

if $OK; then
  python3 "$SCRIPT_DIR/inventario.py" status "$SLUG" ativo

  # Gravado só agora, e não antes: se a atualização falhasse no meio, o
  # arquivo diria que a instância está num commit que ela não está.
  remoto <<EOF
printf '%s' '$COMMIT_ALVO' > '$DEST/.commit-implantado'
EOF

  # Aviso do que sobrou. A remoção acima cobre o que saiu do repo DESDE a
  # última atualização; arquivo que ficou órfão antes disso (ou por edição
  # manual no servidor) não aparece em diff nenhum. Isto não apaga nada —
  # só torna visível, porque o problema original foi justamente ninguém
  # perceber que um arquivo antigo continuava lá.
  NO_REPO="$(mktemp)"; NA_INSTANCIA="$(mktemp)"
  git -C "$APP_REPO" ls-tree -r --name-only HEAD | grep -E "^(${ORFAOS_DIRS// /|})/" | sort > "$NO_REPO"
  remoto <<EOF | cat | sort > "$NA_INSTANCIA"
cd '$DEST'
find $ORFAOS_DIRS -type f 2>/dev/null
EOF
  ORFAOS="$(comm -13 "$NO_REPO" "$NA_INSTANCIA" | grep -vE '^uploads/|/uploads/' || true)"
  rm -f "$NO_REPO" "$NA_INSTANCIA"

  echo ""
  echo "=================================================================="
  echo "'$SLUG' atualizado com sucesso para o commit $COMMIT_ALVO."
  if [[ -n "$ORFAOS" ]]; then
    echo ""
    echo "Aviso: $(printf '%s\n' "$ORFAOS" | grep -c .) arquivo(s) existem nesta"
    echo "instância e NÃO existem no repositório. Não foram tocados — confira"
    echo "se algum deveria ter saído:"
    printf '%s\n' "$ORFAOS" | sed 's/^/  /'
  fi
  echo "=================================================================="
else
  python3 "$SCRIPT_DIR/inventario.py" status "$SLUG" erro
  echo "Erro: '$SLUG' não respondeu em $SAUDE_PATH depois da atualização — investigar (journalctl --user -u $APP_NOME-$SLUG.service no servidor $SERVIDOR, alias SSH: ${SSH_ALIAS:-local}). Backup do banco pré-atualização está em ~/$PASTA_BACKUP/ no servidor (fora da pasta da instância)." >&2
  exit 1
fi
