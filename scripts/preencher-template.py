#!/usr/bin/env python3
"""Preenche um template `{{VARIAVEL}}` sem passar por sed.

Por que existe: o `sed` do provisionamento montava a expressão de
substituição concatenando o VALOR das variáveis. Valor com `|` fechava a
expressão e passava a compor o programa do sed — e a flag `e` do `s///` do
GNU sed executa o espaço de padrão como comando de shell. Achado de
segurança, verificado ao vivo pelo campo `nome` de uma API de criação
de cliente. Substituição literal em Python não tem esse problema:
nenhum caractere do valor tem significado especial.

Valor de credencial pode ter /, & e | e quebrar uma substituição por sed;
aqui vale o mesmo raciocínio para todo o template.

Os VALORES vêm do ambiente, não da linha de comando: argumento de processo
é legível por qualquer usuário da máquina via `ps`, e o `.env` de cliente
carrega segredos como AUTH_SECRET. Só os NOMES das variáveis passam por argv.

Uso:
    AUTH_SECRET=... NOME_NEGOCIO=... \
      preencher-template.py <template> <destino> AUTH_SECRET NOME_NEGOCIO ...

Falha fechada em três casos: variável pedida ausente ou vazia no ambiente,
template inexistente, e — o mais importante na prática — placeholder que
sobrou sem substituição no resultado. Esse último é a rede contra o erro que
já aconteceu (variável nova no template que ninguém passou a preencher,
falhando em silêncio).

Variável prefixada com `?` pode vir vazia, e aí o placeholder dela some do
resultado. Existe porque apareceu a primeira variável legitimamente
opcional (ex.: LOGO_URL: instância sem logo própria mostra só o nome). Marcar caso a caso, em vez de afrouxar a regra pra todo mundo,
mantém a trava fazendo o trabalho dela no que importa: segredo que não foi
gerado continua derrubando o provisionamento, em vez de virar `.env` com
AUTH_SECRET vazio.
"""

import os
import re
import sys

PLACEHOLDER_RE = re.compile(r"\{\{[A-Z_][A-Z0-9_]*\}\}")


def main():
    if len(sys.argv) < 4:
        print("Uso: preencher-template.py <template> <destino> VAR1 [VAR2 ...]",
              file=sys.stderr)
        return 2

    template_path, destino_path = sys.argv[1], sys.argv[2]
    pedidos = sys.argv[3:]

    # "?NOME" = pode vir vazia. O "?" fica só no argv, nunca no template.
    opcionais = {n.lstrip("?") for n in pedidos if n.startswith("?")}
    nomes = [n.lstrip("?") for n in pedidos]

    faltando = [n for n in nomes if n not in opcionais and not os.environ.get(n)]
    if faltando:
        print(f"Erro: variável(is) ausente(s) ou vazia(s) no ambiente: "
              f"{', '.join(faltando)}", file=sys.stderr)
        return 1

    try:
        with open(template_path, encoding="utf-8") as f:
            conteudo = f.read()
    except OSError as erro:
        print(f"Erro ao ler o template '{template_path}': {erro}", file=sys.stderr)
        return 1

    # Substituição literal: str.replace não interpreta nada do valor.
    for nome in nomes:
        conteudo = conteudo.replace("{{" + nome + "}}", os.environ.get(nome, ""))

    sobraram = sorted(set(PLACEHOLDER_RE.findall(conteudo)))
    if sobraram:
        print(f"Erro: placeholder sem valor em '{template_path}': "
              f"{', '.join(sobraram)} — template ganhou variável nova e o script "
              f"que o preenche não foi atualizado junto.", file=sys.stderr)
        return 1

    try:
        # 0600 desde a criação: o .env de cliente sai por aqui e não pode
        # existir nem por um instante legível por outro usuário da máquina.
        fd = os.open(destino_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(conteudo)
    except OSError as erro:
        print(f"Erro ao escrever '{destino_path}': {erro}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
