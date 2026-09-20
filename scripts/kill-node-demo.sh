#!/usr/bin/env bash
# DEMO/teste de tolerância a falhas — derruba 1 ou MAIS nós do Cassandra.
# Rode COM a app de carga ativa e acompanhe em outro terminal: `make app-logs`.
#
# Parâmetros (via env):
#   COUNT=<n>   quantos pods derrubar de uma vez           (default 1)
#   MODE=abrupt crash sem drain (--force --grace-period=0) (default)  <- enunciado
#   MODE=graceful  remoção normal (dispara preStop: nodetool drain)
#   POD=<nome>  derruba um pod ESPECÍFICO (ignora COUNT)
#
# Exemplos:
#   scripts/kill-node-demo.sh                 # 1 pod aleatório, abrupto
#   COUNT=2 scripts/kill-node-demo.sh         # 2 pods aleatórios, abrupto
#   COUNT=3 MODE=graceful scripts/kill-node-demo.sh
#   POD=cassandra-0 scripts/kill-node-demo.sh
#
# ATENÇÃO ao número: com RF=3 e LOCAL_QUORUM (2 de 3), derrubar 1 nó é sempre
# tolerado. Derrubar 2+ pode deixar alguma partição com só 1 réplica viva ->
# essas escritas/leituras em quórum FALHAM (isso é esperado e didático!).
set -euo pipefail
NS="${NS:-sd}"
# CTX: contexto kubectl (usado no setup multi-DC para escolher a regiao).
# Vazio = contexto atual, que e o comportamento de sempre no kind.
CTX="${CTX:-}"
kubectl() { command kubectl ${CTX:+--context "$CTX"} "$@"; }
COUNT="${COUNT:-1}"
MODE="${MODE:-abrupt}"
POD="${POD:-}"

# Escolhe QUALQUER nó vivo para rodar nodetool (o cassandra-0 pode ter sido morto).
pick_live_node() {
  local p
  for p in $(kubectl get pods -n "$NS" -l app=cassandra \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="Running"{print $1}'); do
    if kubectl exec -n "$NS" "$p" -- nodetool status >/dev/null 2>&1; then echo "$p"; return 0; fi
  done
  return 0
}
ring() {
  local h; h="$(pick_live_node)"
  [ -n "$h" ] || { echo "  (nenhum nó respondendo neste instante)"; return 0; }
  kubectl exec -n "$NS" "$h" -- nodetool status 2>/dev/null | grep -E '^(UN|DN)' | awk '{printf "  %s %s\n",$1,$2}' || true
}

# Monta a lista de alvos.
if [ -n "$POD" ]; then
  TARGETS="$POD"
else
  TOTAL=$(kubectl get pods -n "$NS" -l app=cassandra --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$COUNT" -ge "$TOTAL" ]; then
    echo "!! COUNT=$COUNT >= nº de nós ($TOTAL). Recuse-se a derrubar o anel inteiro."
    echo "   Use COUNT menor que $TOTAL."
    exit 1
  fi
  TARGETS=$(kubectl get pods -n "$NS" -l app=cassandra -o name 2>/dev/null | sed 's#pod/##' | sort -R | head -n "$COUNT")
fi

echo "== Anel ANTES da falha =="; ring
echo
echo ">>> Derrubando $(echo "$TARGETS" | wc -w | tr -d ' ') nó(s) [MODE=$MODE]: $(echo $TARGETS)"
for p in $TARGETS; do
  if [ "$MODE" = "graceful" ]; then
    kubectl delete pod -n "$NS" "$p" --now >/dev/null 2>&1 &
  else
    kubectl delete pod -n "$NS" "$p" --grace-period=0 --force >/dev/null 2>&1 &
  fi
done
wait

echo
echo ">>> ~8s após a falha (pode aparecer nó(s) DN = Down, ou já em recriação):"
sleep 8
ring
echo
echo ">>> Acompanhe a app: com COUNT=1 os erros ficam ~0 (RF=3 tolera 1 fora)."
echo "    Com COUNT>=2, alguma partição pode perder quórum -> alguns erros (esperado)."
echo "    make app-logs"
echo ">>> O StatefulSet recria os pods; eles reingressam no anel (voltam a UN)."
