#!/usr/bin/env python3
"""Inventário de clientes: SQLite próprio, fora de qualquer banco de cliente.
Chamado pelos scripts de provisionamento.
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone

DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(DIR, "..", "inventario.db")
SCHEMA_PATH = os.path.join(DIR, "inventario-init.sql")


# Colunas acrescentadas depois que o inventário já existia em disco
# (CREATE TABLE IF NOT EXISTS não adiciona coluna a tabela existente).
COLUNAS_MIGRADAS = {
    "servidor": "TEXT NOT NULL DEFAULT 'dev'",
    "ref_deploy": "TEXT",
}


def conectar():
    db = sqlite3.connect(DB_PATH)
    with open(SCHEMA_PATH) as f:
        db.executescript(f.read())
    # CREATE TABLE IF NOT EXISTS não adiciona coluna nova a uma tabela que
    # já existe — migração manual de coluna, mesmo padrão do resto do
    # projeto. Idempotente: só adiciona o que faltar.
    colunas = {row[1] for row in db.execute("PRAGMA table_info(clientes)")}
    for nome, definicao in COLUNAS_MIGRADAS.items():
        if nome not in colunas:
            db.execute(f"ALTER TABLE clientes ADD COLUMN {nome} {definicao}")
    db.commit()
    os.chmod(DB_PATH, 0o600)
    return db


def cmd_existe(args):
    db = conectar()
    row = db.execute("SELECT 1 FROM clientes WHERE slug = ?", (args.slug,)).fetchone()
    sys.exit(0 if row else 1)


def cmd_adicionar(args):
    db = conectar()
    agora = datetime.now(timezone.utc).isoformat()
    features = json.dumps([f for f in args.features.split(",") if f])
    db.execute(
        "INSERT INTO clientes (slug, nome_negocio, subdominio, porta, path, features, status, servidor, criado_em, atualizado_em)"
        " VALUES (?, ?, ?, ?, ?, ?, 'ativo', ?, ?, ?)",
        (args.slug, args.nome, args.subdominio, args.porta, args.path, features, args.servidor, agora, agora),
    )
    db.commit()


def cmd_listar(args):
    db = conectar()
    for row in db.execute("SELECT slug, nome_negocio, porta, status, servidor FROM clientes ORDER BY criado_em"):
        print(f"{row[0]:20} {row[1]:30} porta={row[2]:<6} {row[3]:<8} servidor={row[4]}")


def cmd_info(args):
    db = conectar()
    cols = ["slug", "nome_negocio", "subdominio", "porta", "path", "features", "status", "servidor",
            "ref_deploy", "criado_em", "atualizado_em"]
    row = db.execute(f"SELECT {', '.join(cols)} FROM clientes WHERE slug = ?", (args.slug,)).fetchone()
    if not row:
        sys.exit(1)
    print(json.dumps(dict(zip(cols, row)), ensure_ascii=False))


def cmd_atualizar(args):
    db = conectar()
    agora = datetime.now(timezone.utc).isoformat()
    features = json.dumps([f for f in args.features.split(",") if f])
    cur = db.execute(
        "UPDATE clientes SET features = ?, status = ?, atualizado_em = ? WHERE slug = ?",
        (features, args.status, agora, args.slug),
    )
    db.commit()
    if cur.rowcount == 0:
        sys.exit(1)


def cmd_definir_ref(args):
    """Fixa (ou solta) a ref de git que este cliente pode receber.

    `--ref ""` solta, e aí o cliente volta a seguir o HEAD do repositório do
    app. Soltar é decisão consciente: é o que libera, por exemplo, uma versão
    nova para um cliente depois de ele aprová-la.
    """
    db = conectar()
    agora = datetime.now(timezone.utc).isoformat()
    ref = (args.ref or "").strip() or None
    cur = db.execute(
        "UPDATE clientes SET ref_deploy = ?, atualizado_em = ? WHERE slug = ?",
        (ref, agora, args.slug),
    )
    db.commit()
    if cur.rowcount == 0:
        sys.exit(1)
    print(f"{args.slug}: ref fixada em {ref}" if ref else f"{args.slug}: ref solta, segue o HEAD")


def cmd_remover(args):
    db = conectar()
    cur = db.execute("DELETE FROM clientes WHERE slug = ?", (args.slug,))
    db.commit()
    if cur.rowcount == 0:
        sys.exit(1)


def cmd_definir_servidor(args):
    """Corrige servidor/path de um cliente já existente (ex.: instância movida
    de máquina antes deste campo existir)."""
    db = conectar()
    agora = datetime.now(timezone.utc).isoformat()
    cur = db.execute(
        "UPDATE clientes SET servidor = ?, path = ?, atualizado_em = ? WHERE slug = ?",
        (args.servidor, args.path, agora, args.slug),
    )
    db.commit()
    if cur.rowcount == 0:
        sys.exit(1)


def cmd_status(args):
    """Só status + atualizado_em — usado pelo healthcheck (usado pelo healthcheck), não
    mexe em features (diferente de "atualizar", que é pra reconciliação)."""
    db = conectar()
    agora = datetime.now(timezone.utc).isoformat()
    cur = db.execute(
        "UPDATE clientes SET status = ?, atualizado_em = ? WHERE slug = ?",
        (args.status, agora, args.slug),
    )
    db.commit()
    if cur.rowcount == 0:
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="comando", required=True)

    p_ref = sub.add_parser("definir-ref", help="fixa a ref de git que este cliente pode receber")
    p_ref.add_argument("slug")
    p_ref.add_argument("--ref", default="", help='vazio solta a trava')
    p_ref.set_defaults(func=cmd_definir_ref)

    p_existe = sub.add_parser("existe", help="sai com código 0 se o slug já existe, 1 se não")
    p_existe.add_argument("slug")
    p_existe.set_defaults(func=cmd_existe)

    p_add = sub.add_parser("adicionar", help="registra um cliente novo")
    p_add.add_argument("slug")
    p_add.add_argument("nome")
    p_add.add_argument("subdominio")
    p_add.add_argument("porta", type=int)
    p_add.add_argument("path")
    p_add.add_argument("features", help="lista separada por vírgula")
    p_add.add_argument("servidor", help="ver servidores.py")
    p_add.set_defaults(func=cmd_adicionar)

    p_list = sub.add_parser("listar", help="lista todos os clientes registrados")
    p_list.set_defaults(func=cmd_listar)

    p_info = sub.add_parser("info", help="imprime o registro do cliente em JSON (sai 1 se não existe)")
    p_info.add_argument("slug")
    p_info.set_defaults(func=cmd_info)

    p_upd = sub.add_parser("atualizar", help="atualiza features/status de um cliente existente")
    p_upd.add_argument("slug")
    p_upd.add_argument("features", help="lista separada por vírgula")
    p_upd.add_argument("status")
    p_upd.set_defaults(func=cmd_atualizar)

    p_rm = sub.add_parser("remover", help="apaga o registro do cliente (sai 1 se não existia)")
    p_rm.add_argument("slug")
    p_rm.set_defaults(func=cmd_remover)

    p_srv = sub.add_parser("definir-servidor", help="corrige servidor/path de um cliente já existente")
    p_srv.add_argument("slug")
    p_srv.add_argument("servidor")
    p_srv.add_argument("path")
    p_srv.set_defaults(func=cmd_definir_servidor)

    p_status = sub.add_parser("status", help="atualiza só o status de um cliente existente (não mexe em features)")
    p_status.add_argument("slug")
    p_status.add_argument("status")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
