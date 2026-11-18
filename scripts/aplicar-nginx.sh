#!/usr/bin/env bash
# Gera/remove o vhost do nginx de um cliente. Roda como root via sudo, com uma
# regra NOPASSWD escopada SÓ a este script (menor privilégio; ver README,
# "Sudoers restrito"). A validação de entrada é feita aqui dentro, sem confiar
# em quem chamou (defesa em profundidade: este script tem privilégio de root).
#
# Uso:
#   aplicar-nginx.sh criar <slug> <subdominio-completo> <porta>
#   aplicar-nginx.sh remover <slug>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"

ACAO="${1:-}"
SLUG="${2:-}"

validar_slug() {
  if ! [[ "$SLUG" =~ ^[a-z0-9-]+$ ]]; then
    echo "Slug inválido: '$SLUG'" >&2
    exit 1
  fi
}

case "$ACAO" in
  criar)
    SUBDOMINIO="${3:-}"
    PORTA="${4:-}"
    if [[ -z "$SLUG" || -z "$SUBDOMINIO" || -z "$PORTA" ]]; then
      echo "Uso: $0 criar <slug> <subdominio-completo> <porta>" >&2
      exit 1
    fi
    validar_slug
    if ! [[ "$SUBDOMINIO" =~ ^[a-z0-9-]+\.[a-z0-9.-]+$ ]]; then
      echo "Subdomínio inválido: '$SUBDOMINIO'" >&2
      exit 1
    fi
    if ! [[ "$PORTA" =~ ^[0-9]+$ ]] || (( PORTA < 1024 || PORTA > 65535 )); then
      echo "Porta inválida: '$PORTA'" >&2
      exit 1
    fi

    CONF_DEST="/etc/nginx/sites-available/$SLUG.conf"
    sed \
      -e "s|{{SLUG}}|$SLUG|g" \
      -e "s|{{SUBDOMINIO}}|$SUBDOMINIO|g" \
      -e "s|{{PORTA}}|$PORTA|g" \
      "$TEMPLATES_DIR/nginx.conf.template" > "$CONF_DEST"
    ln -sf "$CONF_DEST" "/etc/nginx/sites-enabled/$SLUG.conf"
    nginx -t
    systemctl reload nginx
    echo "Nginx configurado pra $SUBDOMINIO -> 127.0.0.1:$PORTA"
    ;;

  remover)
    if [[ -z "$SLUG" ]]; then
      echo "Uso: $0 remover <slug>" >&2
      exit 1
    fi
    validar_slug
    rm -f "/etc/nginx/sites-enabled/$SLUG.conf" "/etc/nginx/sites-available/$SLUG.conf"
    nginx -t
    systemctl reload nginx
    echo "Nginx removido pra '$SLUG'"
    ;;

  *)
    echo "Uso: $0 criar <slug> <subdominio-completo> <porta>" >&2
    echo "  ou: $0 remover <slug>" >&2
    exit 1
    ;;
esac
