#!/usr/bin/env python3
"""Gera o `.env.systemd` a partir do `.env` real de um cliente — cópia
igual, exceto que omite qualquer variável cujo VALOR contenha um `$`.

Por quê: o systemd carrega o .env do cliente via `EnvironmentFile=`
ANTES da aplicação subir, e o parser dele tenta expandir `$` como
variável — mesmo com o valor escapado como `\\$` no arquivo, o systemd
ainda quebra em silêncio (a variável vira string vazia, sem erro
nenhum). Caso real: uma chave de API de terceiro cujo valor começa com `$`
ficava vazia em produção, e como o carregador de .env do framework não
sobrescreve uma variável que o systemd já colocou no ambiente, o `.env`
certo por baixo nunca era lido para essa chave.

A variável excluída aqui continua existindo normalmente no `.env`
principal — só não entra no arquivo que o systemd pré-carrega. A
aplicação lê o `.env` sozinha no boot e preenche a variável sem esse
problema (dotenv não expande `$`).

Uso: gerar-env-systemd.py <caminho-do-.env> <caminho-do-.env.systemd>
"""

import re
import sys

LINHA_VAR_RE = re.compile(r'^([A-Z_][A-Z0-9_]*)=(.*)$')


def main():
    if len(sys.argv) != 3:
        print("Uso: gerar-env-systemd.py <.env> <.env.systemd>", file=sys.stderr)
        sys.exit(1)

    env_path, destino_path = sys.argv[1], sys.argv[2]

    with open(env_path) as f:
        linhas = f.readlines()

    omitidas = []
    novas_linhas = [
        "# Gerado automaticamente por gerar-env-systemd.py a partir do .env\n",
        "# real deste cliente — não editar à mão, as mudanças se perdem na\n",
        "# próxima atualização de credenciais ou provisionamento. Variáveis\n",
        "# cujo valor contém \"$\" ficam de fora de propósito (ver docstring\n",
        "# do script) — elas continuam normalmente no .env principal.\n",
        "\n",
    ]
    for linha in linhas:
        m = LINHA_VAR_RE.match(linha)
        if m and "$" in m.group(2):
            omitidas.append(m.group(1))
            novas_linhas.append(f"# {m.group(1)} omitida aqui de propósito (valor contém \"$\", ver .env)\n")
        else:
            novas_linhas.append(linha)

    with open(destino_path, "w") as f:
        f.writelines(novas_linhas)

    if omitidas:
        print(f"{len(omitidas)} variável(is) omitida(s) do .env.systemd (valor com \"$\"): {', '.join(sorted(omitidas))}")
    else:
        print(".env.systemd gerado, nenhuma variável com \"$\" encontrada")


if __name__ == "__main__":
    main()
