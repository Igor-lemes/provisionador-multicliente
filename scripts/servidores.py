#!/usr/bin/env python3
"""Registro dos servidores onde uma instância de cliente pode rodar.

Só duas entradas, de propósito: generalizar para N servidores antes de
precisar seria excesso de engenharia. Uma terceira VPS é só uma chave nova.

"dev":      a própria VPS onde o control plane roda (execução local, sem SSH).
"producao": a VPS dos clientes reais (execução via SSH).

`clientes_dir` é a pasta-base das instâncias NAQUELE servidor, declarada
explicitamente. Calcular a partir da pasta local de quem roda o script foi o
bug real que apontou para um caminho inexistente na produção (ver README,
Limitações). Um cliente já registrado no inventário usa o `path` dele, que
prevalece sobre isto (resolver_dest).
"""

import posixpath
import re

SERVIDORES = {
    "dev": {
        "ssh_alias": None,  # None = executa local
        "ip_publico": "203.0.113.10",
        "clientes_dir": None,  # não recebe provisionamento
    },
    "producao": {
        "ssh_alias": "vps-producao",  # alias em ~/.ssh/config
        "ip_publico": "203.0.113.20",
        "clientes_dir": "/home/deploy/clientes",
    },
}

PADRAO = "producao"

# O destino entra em heredocs com aspas simples e em `rm -rf`: só caminho
# absoluto, sem "..", sem espaço nem aspas.
_CAMINHO_SEGURO = re.compile(r"^/[A-Za-z0-9._/-]+$")


def validar(servidor):
    if servidor not in SERVIDORES:
        raise ValueError(f"Servidor desconhecido: '{servidor}' (válidos: {', '.join(SERVIDORES)})")
    return SERVIDORES[servidor]


def clientes_dir(servidor):
    base = validar(servidor).get("clientes_dir")
    if not base:
        raise ValueError(f"Servidor '{servidor}' não tem clientes_dir (não recebe provisionamento)")
    return base


def resolver_dest(servidor, slug, path_inventario=""):
    """Pasta da instância: o `path` do inventário se houver, senão
    <clientes_dir>/<slug>. Sem fallback para a pasta local."""
    if not re.fullmatch(r"[a-z0-9-]+", slug or ""):
        raise ValueError(f"Slug inválido: '{slug}'")
    dest = path_inventario.rstrip("/") if path_inventario else f"{clientes_dir(servidor)}/{slug}"
    # normpath == dest recusa ".", ".." e "//" (forma não canônica).
    if not _CAMINHO_SEGURO.match(dest) or "//" in dest or posixpath.normpath(dest) != dest:
        raise ValueError(f"Caminho de instância inválido: '{dest}'")
    return dest


def checar_remocao(servidor, slug, dest):
    """Guardas do `rm -rf` do remover-cliente.sh. True se a pasta é a padrão
    (<base>/<slug>); False se está fora do padrão (exige --tenho-certeza);
    ValueError se for para recusar de vez."""
    dest = resolver_dest(servidor, slug, dest)
    if len(dest.split("/")) - 1 < 3:
        raise ValueError(f"'{dest}' é raso demais para ser pasta de instância")
    for nome, info in SERVIDORES.items():
        base = info.get("clientes_dir")
        if base and (base + "/").startswith(dest + "/"):
            raise ValueError(f"'{dest}' é a pasta-base das instâncias de '{nome}' (ou um ancestral dela)")
    base = SERVIDORES[servidor].get("clientes_dir")
    return bool(base) and dest == f"{base}/{slug}"


if __name__ == "__main__":
    # Uso pelo lado bash:
    #   servidores.py <servidor>                              -> "ssh_alias|ip_publico"
    #   servidores.py clientes-dir <servidor>                 -> pasta-base
    #   servidores.py resolver <servidor> <slug> [path]       -> pasta da instância
    #   servidores.py checar-remocao <servidor> <slug> <dest> -> exit 0 padrão, 2 fora do padrão, 1 recusa
    import sys

    args = sys.argv[1:]
    try:
        if args and args[0] == "clientes-dir" and len(args) == 2:
            print(clientes_dir(args[1]))
        elif args and args[0] == "resolver" and len(args) in (3, 4):
            print(resolver_dest(args[1], args[2], args[3] if len(args) == 4 else ""))
        elif args and args[0] == "checar-remocao" and len(args) == 4:
            sys.exit(0 if checar_remocao(args[1], args[2], args[3]) else 2)
        elif len(args) == 1:
            info = validar(args[0])
            print(f"{info['ssh_alias'] or ''}|{info['ip_publico']}")
        else:
            print("Uso: servidores.py <servidor> | clientes-dir <servidor> | resolver <servidor> <slug> [path] | checar-remocao <servidor> <slug> <dest>", file=sys.stderr)
            sys.exit(1)
    except ValueError as e:
        print(e, file=sys.stderr)
        sys.exit(1)
