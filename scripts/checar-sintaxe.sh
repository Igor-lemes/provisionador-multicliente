#!/usr/bin/env bash
# Checagem de sintaxe para CI: o repositório é Python + Bash, sem framework
# de build. Roda ast.parse em todo .py e bash -n em todo .sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$SCRIPT_DIR/.." && pwd)"
FALHOU=0

echo "==> Python (.py)"
while IFS= read -r -d '' arquivo; do
  if python3 -c "import ast; ast.parse(open('$arquivo').read())" 2>/tmp/erro-py; then
    echo "  OK   $arquivo"
  else
    echo "  FALHOU $arquivo"
    cat /tmp/erro-py
    FALHOU=1
  fi
done < <(find "$RAIZ" -name "*.py" -not -path "*/__pycache__/*" -print0)

echo "==> Bash (.sh)"
while IFS= read -r -d '' arquivo; do
  if bash -n "$arquivo" 2>/tmp/erro-sh; then
    echo "  OK   $arquivo"
  else
    echo "  FALHOU $arquivo"
    cat /tmp/erro-sh
    FALHOU=1
  fi
done < <(find "$RAIZ" -name "*.sh" -print0)

exit $FALHOU
