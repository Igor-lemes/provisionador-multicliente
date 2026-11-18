#!/usr/bin/env python3
"""Quais arquivos SAÍRAM do repositório do app entre dois commits.

Existe porque `git archive HEAD | tar -x`, que é como o código chega na
instância do cliente, só ACRESCENTA e SOBRESCREVE, nunca apaga. Um arquivo
removido do repositório continua vivo na instância para sempre. Caso real: um
ícone foi removido do código, as três instâncias foram atualizadas e as três
continuaram servindo o ícone antigo, porque o arquivo nunca saiu do disco.

A lista vem do GIT, não de varredura de diretório. Essa é a diferença para um
`rsync --delete`: com varredura, qualquer coisa que exista na instância e não
no repositório seria candidata a sumir, inclusive `.env`, o banco,
`node_modules/` e os uploads do cliente, que são dado real e não versionado.

Uso:
    arquivos-removidos.py <repo> <commit-antigo> [commit-novo]

Imprime um caminho por linha, relativo à raiz da instância. Sai com 0 mesmo
quando não há nada a remover: ausência de remoção não é erro.
"""

import subprocess
import sys

# Segunda trava, em profundidade. O git só reporta caminho versionado, então
# nada disto deveria aparecer, mas se um dia alguém versionar um `.env` por
# engano e depois removê-lo, a remoção aqui apagaria o `.env` REAL do cliente,
# que não tem backup e derruba a instância.
PROTEGIDOS = (
    ".env",
    "dev.db",
    "backups/",
    "uploads/",
    "node_modules/",
    ".next/",
    ".commit-implantado",
)


def seguro(caminho):
    """Caminho que pode ser apagado sem risco de levar dado do cliente."""
    if not caminho or caminho.startswith("/") or ".." in caminho.split("/"):
        return False
    return not any(caminho == p or caminho.startswith(p) for p in PROTEGIDOS)


def main():
    if len(sys.argv) < 3:
        print("Uso: arquivos-removidos.py <repo> <commit-antigo> [commit-novo]", file=sys.stderr)
        return 2

    repo, antigo = sys.argv[1], sys.argv[2]
    novo = sys.argv[3] if len(sys.argv) > 3 else "HEAD"

    # Commit desconhecido (rebase, force push, instância antiga demais) não é
    # erro fatal: sem base de comparação, o certo é não apagar nada.
    conhece = subprocess.run(
        ["git", "-C", repo, "cat-file", "-e", f"{antigo}^{{commit}}"],
        capture_output=True,
    )
    if conhece.returncode != 0:
        print(f"Aviso: commit '{antigo}' não existe em {repo} — nada será removido.", file=sys.stderr)
        return 0

    # --no-renames: arquivo MOVIDO (git mv) também saiu do caminho antigo. Sem
    # a flag, o git junta apagado + criado num "renomeado" (R), o filtro D não
    # o vê e o caminho velho fica na instância (páginas velhas ao lado das
    # novas na mesma URL, build quebrado).
    r = subprocess.run(
        ["git", "-C", repo, "diff", "--no-renames", "--name-only", "--diff-filter=D", f"{antigo}..{novo}"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"Aviso: git diff falhou ({r.stderr.strip()[:200]}) — nada será removido.", file=sys.stderr)
        return 0

    recusados = []
    for linha in r.stdout.splitlines():
        caminho = linha.strip()
        if not caminho:
            continue
        if seguro(caminho):
            print(caminho)
        else:
            recusados.append(caminho)

    if recusados:
        print(f"Aviso: {len(recusados)} caminho(s) recusado(s) por segurança: "
              f"{', '.join(recusados[:5])}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
