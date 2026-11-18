#!/usr/bin/env python3
"""Cria/atualiza ou remove o registro DNS de um cliente na API da Cloudflare.

"criar" é idempotente: se o subdomínio já tem registro A, atualiza em vez de
duplicar. "remover" não é erro se o registro já não existir, para poder rodar
de novo sem medo.

Uso:
  criar-dns.py criar <subdominio-completo> [ip]
  criar-dns.py remover <subdominio-completo>
Ex.: criar-dns.py criar cliente-a.exemplo.com 203.0.113.20

[ip] é opcional; se omitido, usa VPS_IP_PUBLICO do .env. Quem chama
(provisionar-cliente.sh) passa o IP do servidor escolhido (servidores.py).

Precisa de CLOUDFLARE_API_TOKEN e CLOUDFLARE_ZONE_ID no .env da raiz do
projeto (ver .env.example). O token precisa só da permissão "Zone > DNS > Edit"
na zona dos clientes, nunca de um token de conta inteira (menor privilégio).
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.join(DIR, "..")
API_BASE = "https://api.cloudflare.com/client/v4"
SUBDOMINIO_RE = re.compile(r"^[a-z0-9-]+\.[a-z0-9.-]+$")


def carregar_env():
    env = {}
    with open(os.path.join(RAIZ, ".env")) as f:
        for linha in f:
            linha = linha.strip()
            if not linha or linha.startswith("#") or "=" not in linha:
                continue
            chave, valor = linha.split("=", 1)
            env[chave.strip()] = valor.strip().strip('"')
    return env


def chamar_cloudflare(token, metodo, caminho, corpo=None):
    dados = json.dumps(corpo).encode() if corpo is not None else None
    req = urllib.request.Request(
        f"{API_BASE}{caminho}",
        data=dados,
        method=metodo,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        corpo_erro = e.read().decode(errors="replace")
        raise RuntimeError(f"Cloudflare respondeu {e.code}: {corpo_erro}") from None


def buscar_registro(token, zone_id, subdominio):
    existentes = chamar_cloudflare(token, "GET", f"/zones/{zone_id}/dns_records?type=A&name={subdominio}")
    registros = existentes.get("result", [])
    return registros[0] if registros else None


def main():
    if len(sys.argv) not in (3, 4) or sys.argv[1] not in ("criar", "remover"):
        print("Uso: criar-dns.py criar <subdominio-completo> [ip] | remover <subdominio-completo>", file=sys.stderr)
        sys.exit(1)

    acao, subdominio = sys.argv[1], sys.argv[2]
    ip_arg = sys.argv[3] if len(sys.argv) == 4 else None
    if not SUBDOMINIO_RE.match(subdominio):
        print(f"Subdomínio inválido: {subdominio!r}", file=sys.stderr)
        sys.exit(1)

    env = carregar_env()
    token = env.get("CLOUDFLARE_API_TOKEN")
    zone_id = env.get("CLOUDFLARE_ZONE_ID")
    vps_ip = ip_arg or env.get("VPS_IP_PUBLICO")
    if not token or not zone_id or (acao == "criar" and not vps_ip):
        print("Faltando CLOUDFLARE_API_TOKEN, CLOUDFLARE_ZONE_ID, ou IP (nem passado nem VPS_IP_PUBLICO no .env)", file=sys.stderr)
        sys.exit(1)

    if acao == "criar":
        registro = buscar_registro(token, zone_id, subdominio)
        corpo = {"type": "A", "name": subdominio, "content": vps_ip, "proxied": True, "ttl": 1}
        if registro:
            chamar_cloudflare(token, "PUT", f"/zones/{zone_id}/dns_records/{registro['id']}", corpo)
            print(f"DNS atualizado: {subdominio} -> {vps_ip} (registro existente {registro['id']})")
        else:
            criado = chamar_cloudflare(token, "POST", f"/zones/{zone_id}/dns_records", corpo)
            print(f"DNS criado: {subdominio} -> {vps_ip} (registro {criado['result']['id']})")
    else:
        registro = buscar_registro(token, zone_id, subdominio)
        if not registro:
            print(f"DNS de '{subdominio}' já não existia, nada a fazer")
            return
        chamar_cloudflare(token, "DELETE", f"/zones/{zone_id}/dns_records/{registro['id']}")
        print(f"DNS removido: {subdominio} (registro {registro['id']})")


if __name__ == "__main__":
    main()
