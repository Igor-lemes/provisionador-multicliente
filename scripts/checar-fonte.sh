#!/usr/bin/env bash
# Garante que o checkout do repositório do app está em dia antes de virar
# código de cliente.
#
# Por que existe: mergear no GitHub não atualiza o disco da VPS, e é do disco
# que sai o `git archive HEAD` de todo cliente novo. Depois de uma leva de
# merges de segurança o checkout em disco continuava atrasado: um cliente
# provisionado naquele momento nasceria com a falha já corrigida no remoto
# ainda aberta. Só apareceu porque alguém pensou em conferir; nada avisava.
#
# Comportamento, quando a árvore está limpa: atualiza sozinho com
# `git pull --ff-only`. Não é atrevimento — `--ff-only` nunca reescreve
# histórico nem descarta trabalho, e a alternativa (abortar pedindo um
# `git pull` manual) trava quem dispara provisionamento por uma interface web,
# onde não há terminal para rodar o comando.
#
# Quando NÃO está limpa (arquivo modificado, merge pela metade, branch sem
# upstream), aborta e explica. Nesse caso a intervenção é humana mesmo:
# alguém deixou trabalho ali, e sobrescrever seria pior.
#
# Com --so-conferir, NÃO atualiza nada: só diz se está em dia (exit 0) ou
# atrasado (exit 3). É esse modo que o healthcheck usa — um timer puxando
# código sozinho, sem ninguém olhando, é o oposto do que se quer num
# control plane.
#
# Uso:  checar-fonte.sh <caminho-do-repo> [rotulo] [--so-conferir]

set -euo pipefail

REPO="${1:-}"
ROTULO="${2:-$(basename "${REPO:-repo}")}"
SO_CONFERIR=false
for arg in "$@"; do [[ "$arg" == "--so-conferir" ]] && SO_CONFERIR=true; done

if [[ -z "$REPO" || ! -d "$REPO/.git" ]]; then
  echo "Erro: '$REPO' não é um repositório git." >&2
  exit 1
fi

BRANCH="$(git -C "$REPO" branch --show-current 2>/dev/null || true)"
if [[ -z "$BRANCH" ]]; then
  echo "Erro: o checkout de $ROTULO não está numa branch (HEAD solto)." >&2
  echo "      Provisionar a partir daí geraria cliente de um estado que ninguém consegue reproduzir depois." >&2
  exit 1
fi

if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
  echo "Erro: o checkout de $ROTULO tem alteração local não commitada." >&2
  echo "      Não vou atualizar nem provisionar por cima: o código que iria pro cliente não" >&2
  echo "      corresponderia a nenhum commit, e alguém pode ter trabalho ali." >&2
  echo "      Resolva em $REPO (commitar, descartar ou guardar) e rode de novo." >&2
  git -C "$REPO" status --short | sed 's/^/        /' >&2
  exit 1
fi

UPSTREAM="$(git -C "$REPO" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
if [[ -z "$UPSTREAM" ]]; then
  echo "Erro: a branch '$BRANCH' de $ROTULO não acompanha nenhuma branch remota." >&2
  echo "      Sem isso não dá pra saber se o código está em dia." >&2
  exit 1
fi

if ! git -C "$REPO" fetch --quiet origin "$BRANCH" 2>/dev/null; then
  echo "Aviso: não consegui falar com o origin pra conferir se $ROTULO está em dia." >&2
  echo "       Seguindo com o que está em disco ($(git -C "$REPO" rev-parse --short HEAD))." >&2
  exit 0
fi

ATRAS="$(git -C "$REPO" rev-list --count "HEAD..$UPSTREAM")"
if [[ "$ATRAS" -eq 0 ]]; then
  echo "==> $ROTULO em dia com $UPSTREAM ($(git -C "$REPO" rev-parse --short HEAD))"
  exit 0
fi

if $SO_CONFERIR; then
  echo "ATRASADO: $ROTULO está $ATRAS commit(s) atrás de $UPSTREAM" >&2
  git -C "$REPO" --no-pager log --oneline "HEAD..$UPSTREAM" | sed 's/^/      /' >&2
  exit 3
fi

echo "==> $ROTULO está $ATRAS commit(s) atrás de $UPSTREAM — atualizando antes de copiar o código"
git -C "$REPO" --no-pager log --oneline "HEAD..$UPSTREAM" | sed 's/^/      /'
if ! git -C "$REPO" pull --quiet --ff-only origin "$BRANCH"; then
  echo "Erro: o fast-forward de $ROTULO falhou — o checkout divergiu do remoto." >&2
  echo "      Resolver à mão em $REPO antes de provisionar." >&2
  exit 1
fi
echo "==> $ROTULO atualizado ($(git -C "$REPO" rev-parse --short HEAD))"
