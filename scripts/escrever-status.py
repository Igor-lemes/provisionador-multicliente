#!/usr/bin/env python3
"""Escreve o status de progresso de um provisionamento em andamento
— chamado pelo provisionar-cliente.sh a cada etapa. Escreve
num arquivo temporário e troca com os.replace (atômico), pra quem está
lendo (API de controle, via polling) nunca pegar um JSON pela metade.

Uso: escrever-status.py <arquivo> <indice> <total> <etapa> <comando> <status>
"""
import json
import os
import sys


def main():
    arquivo, indice, total, etapa, comando, status = sys.argv[1:7]
    dados = {
        "indice": int(indice),
        "total": int(total),
        "etapa": etapa,
        "comando": comando,
        "status": status,
    }
    tmp = arquivo + ".tmp"
    with open(tmp, "w") as f:
        json.dump(dados, f)
    os.chmod(tmp, 0o600)  # a saída do provisionamento acaba aqui e inclui a
    # senha temporária do admin em texto puro: não pode ficar legível por
    # outro usuário da VPS.
    os.replace(tmp, arquivo)


if __name__ == "__main__":
    main()
