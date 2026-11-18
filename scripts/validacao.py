#!/usr/bin/env python3
"""Regras de validação de entrada compartilhadas entre a API de controle e os
scripts de provisionamento.

Mora num módulo só de propósito: a mesma regra precisa valer para quem entra
por uma API e para quem chama o script direto na CLI. Duas cópias divergem, e
foi assim que o `nome` acabou sem validação nenhuma enquanto o `slug` tinha a
dele em dois lugares.

Uso como módulo:
    from validacao import nome_negocio_valido
Uso como CLI (é assim que o bash chama):
    validacao.py nome "<valor>"     # exit 0 se válido, 1 + mensagem se não
"""

import re
import sys

# Allowlist, não blocklist. O nome do negócio é texto livre digitado por uma
# pessoa e acaba em três lugares que tratam caractere de forma especial:
#   - .env do cliente, dentro de aspas duplas (NOME_NEGOCIO="...")  -> " $ \ e
#     quebra de linha quebrariam o arquivo
#   - Description= das units systemd                                -> % é
#     especificador do systemd, quebra de linha encerra a diretiva
#   - argumentos de shell nos scripts                                -> | ` ; $
#     e afins podem virar execução de comando (num caso real, o valor entrava
#     cru numa expressão sed e a flag `e` do s/// do GNU sed executava o
#     espaço de padrão como comando)
# Listar o que ENTRA fecha os três de uma vez, incluindo o que ninguém pensou.
# Acentos e cedilha entram, assim como apóstrofo e & (ex.: "Imóveis D'Ávila & Cia").
NOME_NEGOCIO_RE = re.compile(r"^[0-9A-Za-zÀ-ÖØ-öø-ÿ .,&()'+\-]{1,80}$")

MSG_NOME = (
    "nome inválido — use só letras (com acento), números, espaço e . , & ( ) ' + -, "
    "até 80 caracteres"
)


def nome_negocio_valido(valor):
    """True se o nome do negócio pode ser usado com segurança nos templates."""
    return isinstance(valor, str) and bool(NOME_NEGOCIO_RE.match(valor))


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "nome":
        print('Uso: validacao.py nome "<valor>"', file=sys.stderr)
        return 2
    if not nome_negocio_valido(sys.argv[2]):
        print(f"{MSG_NOME} (recebido: {sys.argv[2]!r})", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
