#!/usr/bin/env bash
# Reconciliação — aplica uma lista nova de
# features num cliente já provisionado: reescreve só a linha
# FEATURES_ENABLED do .env dele (preserva AUTH_SECRET/CRON_SECRET/etc.,
# nunca regenera segredo em reconciliação de rotina), regera o
# .env.systemd a partir dele, reinicia o serviço, confirma que voltou a
# responder, e atualiza o inventário.
#
# Uso:
#   ./reconciliar.sh <slug> <features-csv> [--tenho-certeza]
#
# Slugs protegidos (instância de cliente pagante) exigem --tenho-certeza
# explícito — a API de controle nunca passa esse argumento, de propósito
# (mesmo padrão do remover-cliente.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"   # define PROTEGIDOS e SAUDE_PATH


SLUG="${1:-}"
FEATURES="${2:-}"
TENHO_CERTEZA="${3:-}"

if [[ -z "$SLUG" || -z "$FEATURES" ]]; then
  echo "Uso: $0 <slug> <features-csv> [--tenho-certeza]" >&2
  exit 1
fi
# Mesma checagem do provisionar-cliente.sh/resetar-senha.sh/remover-cliente.sh:
# o slug vira caminho de pasta e nome de unit systemd dentro de heredoc, então
# valida aqui em vez de contar com quem chamou .
if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
  echo "Slug inválido: '$SLUG' — só minúsculo, número e hífen (ex: cliente-a)." >&2
  exit 1
fi

# Nome de módulo é minúsculo, dígito e hífen, separado por vírgula — nada
# mais. Logo abaixo o valor entra num sed e num heredoc executado por bash:
# aspas, $(...) ou | comporiam comando. Validar o formato aqui fecha o vetor.
if ! [[ "$FEATURES" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then
  echo "Features inválidas: '$FEATURES' — esperado nomes separados por vírgula, só minúsculo, número e hífen (ex: crm,inbox,video-imovel)." >&2
  exit 1
fi

for protegido in "${PROTEGIDOS[@]}"; do
  if [[ "$SLUG" == "$protegido" && "$TENHO_CERTEZA" != "--tenho-certeza" ]]; then
    echo "'$SLUG' é um slug protegido (cliente em produção). Editar módulos por aqui exige --tenho-certeza explícito na CLI — se for isso mesmo, adicione o argumento. Se não tinha certeza, pare agora." >&2
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
IFS='|' read -r SSH_ALIAS IP_SERVIDOR < <(python3 "$SCRIPT_DIR/servidores.py" "$SERVIDOR")
remoto() {
  if [[ -z "$SSH_ALIAS" ]]; then
    bash -c "$(cat)"
  else
    ssh "$SSH_ALIAS" bash -s <<< "$(cat)"
  fi
}

# Pasta da instância NO SERVIDOR: o path do inventário (instâncias fora do
# layout padrão), senão a base do servidor. Nunca a pasta local daqui: esse
# caminho não existe na produção.
CAMINHO_INVENTARIO="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('path') or '')" "$INFO")"
DEST="$(python3 "$SCRIPT_DIR/servidores.py" resolver "$SERVIDOR" "$SLUG" "$CAMINHO_INVENTARIO")"
if ! remoto <<< "[[ -d '$DEST' && -f '$DEST/.env' ]]"; then
  echo "Erro: $DEST/.env não existe no servidor '$SERVIDOR' (inventário e disco dessincronizados)." >&2
  exit 1
fi

echo "==> Reconciliando '$SLUG' (servidor: $SERVIDOR): features → $FEATURES"

# O serviço lê o .env.systemd (EnvironmentFile do template de unit), e o que o
# systemd põe no ambiente ganha do .env. Se esta rotina mexesse só no .env,
# ligar ou desligar uma função não teria efeito até alguém regenerar o
# .env.systemd. Por isso: busca o .env, troca a linha, gera o .env.systemd
# com gerar-env-systemd.py e manda os dois de volta.
ENV_LOCAL="$(mktemp)"
ENV_SYSTEMD_LOCAL="$(mktemp)"
limpar() { rm -f "$ENV_LOCAL" "$ENV_SYSTEMD_LOCAL"; }
trap limpar EXIT

if [[ -z "$SSH_ALIAS" ]]; then
  cp "$DEST/.env" "$ENV_LOCAL"
else
  scp -q "$SSH_ALIAS:$DEST/.env" "$ENV_LOCAL"
fi

# $FEATURES já passou pela regex lá em cima (só minúsculo, dígito, hífen e
# vírgula): seguro dentro do sed.
sed -i "s|^FEATURES_ENABLED=.*|FEATURES_ENABLED=\"$FEATURES\"|" "$ENV_LOCAL"
python3 "$SCRIPT_DIR/gerar-env-systemd.py" "$ENV_LOCAL" "$ENV_SYSTEMD_LOCAL"

if [[ -z "$SSH_ALIAS" ]]; then
  cp "$ENV_LOCAL" "$DEST/.env"
  cp "$ENV_SYSTEMD_LOCAL" "$DEST/.env.systemd"
else
  scp -q "$ENV_LOCAL" "$SSH_ALIAS:$DEST/.env"
  scp -q "$ENV_SYSTEMD_LOCAL" "$SSH_ALIAS:$DEST/.env.systemd"
fi
echo "==> .env (só a linha FEATURES_ENABLED, resto preservado) e .env.systemd atualizados"

remoto <<EOF
systemctl --user restart '$APP_NOME-$SLUG.service'
EOF
echo "==> Serviço reiniciado"

OK=false
for _ in $(seq 1 15); do
  if remoto <<< "curl -sf 'http://localhost:$PORTA$SAUDE_PATH' -o /dev/null"; then
    OK=true
    break
  fi
  sleep 1
done

if $OK; then
  python3 "$SCRIPT_DIR/inventario.py" atualizar "$SLUG" "$FEATURES" ativo
  echo "==> Healthcheck OK — inventário atualizado (status: ativo)"
  python3 "$SCRIPT_DIR/gerar-targets-prometheus.py"
  echo "==> Alvo do Prometheus atualizado"
else
  python3 "$SCRIPT_DIR/inventario.py" atualizar "$SLUG" "$FEATURES" erro
  python3 "$SCRIPT_DIR/gerar-targets-prometheus.py"
  echo "Erro: '$SLUG' não respondeu em http://localhost:$PORTA$SAUDE_PATH (servidor $SERVIDOR) depois do restart." >&2
  exit 1
fi
