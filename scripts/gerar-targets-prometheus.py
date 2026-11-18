#!/usr/bin/env python3
"""Gera o file_sd_config do Prometheus (job blackbox-clientes) a partir do
inventário. Chamado pelos scripts de provisionamento sempre que o inventário
muda; o arquivo de alvos nunca é editado à mão.

Variáveis de ambiente (opcionais):
  TARGETS_PATH  onde gravar (padrão /etc/prometheus/targets/clientes.json)
  SAUDE_PATH    rota de saúde das instâncias (padrão /health)
"""

import json
import os
import sqlite3

DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(DIR, "..", "inventario.db")
TARGETS_PATH = os.environ.get("TARGETS_PATH", "/etc/prometheus/targets/clientes.json")
SAUDE_PATH = os.environ.get("SAUDE_PATH", "/health")


def url_de_saude(servidor, porta, subdominio):
    """"dev" é a própria VPS do control plane, então localhost resolve. Para
    qualquer outro servidor, localhost seria a máquina errada, e ir pelo
    domínio público é melhor de qualquer jeito: pega também problema de DNS,
    CDN e firewall, não só "o processo está de pé" (num incidente real o
    processo respondia e o cliente não conseguia entrar)."""
    if servidor == "dev":
        return f"http://localhost:{porta}{SAUDE_PATH}"
    return f"https://{subdominio}{SAUDE_PATH}"


def gerar():
    db = sqlite3.connect(DB_PATH)
    clientes = db.execute("SELECT slug, porta, servidor, subdominio FROM clientes").fetchall()
    alvos = [
        {"targets": [url_de_saude(servidor, porta, subdominio)], "labels": {"slug": slug}}
        for slug, porta, servidor, subdominio in clientes
    ]
    tmp = TARGETS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(alvos, f, indent=2)
    os.replace(tmp, TARGETS_PATH)  # atômico: o Prometheus nunca lê JSON pela metade


if __name__ == "__main__":
    gerar()
