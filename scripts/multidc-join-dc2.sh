#!/usr/bin/env bash
# Adiciona o dc2 ao keyspace — procedimento oficial de "adding a datacenter".
#
#   1. Confere que os 6 nós já se enxergam no anel (gossip cruzando o peering).
#   2. ALTER KEYSPACE: passa a replicar em dc1:3 E dc2:3.
#   3. nodetool rebuild em CADA nó do dc2: puxa do dc1 os dados que agora lhe
#      pertencem. Sem este passo o dc2 fica no anel mas VAZIO — e leituras
#      LOCAL_QUORUM no dc2 devolveriam dados faltando.
#   4. (o gerador de carga roda só no dc1 — ver make mdc-loadgen-dc2-on)
set -euo pipefail
NS="${NS:-sd}"
CTX1="${CTX1:?contexto kubectl do dc1}"
CTX2="${CTX2:?contexto kubectl do dc2}"
PODS_DC2="${PODS_DC2:-cassandra-rack1-0 cassandra-rack1-1 cassandra-rack2-0}"
SEED1="${SEED1:-cassandra-rack1-0}"

echo "== 1. Anel visto pelo dc1 (esperado: 6 nós UN, 3 por DC) =="
kubectl --context "$CTX1" exec -n "$NS" "$SEED1" -- nodetool status

UP=$(kubectl --context "$CTX1" exec -n "$NS" "$SEED1" -- nodetool status 2>/dev/null | grep -c '^UN' || true)
if [ "$UP" -lt 6 ]; then
  echo "!! Só $UP nós UN. O gossip entre as regiões ainda não fechou."
  echo "   Cheque o peering e as NSGs (porta 7000 entre 10.10.32.0/24 e 10.20.32.0/24)."
  exit 1
fi

echo
echo "== 2. ALTER KEYSPACE: replicando também no dc2 =="
# Os keyspaces de sistema também precisam existir nos dois DCs, senão login e
# tabelas de coordenação ficam só de um lado.
for KS_RF in "sd_demo:3" "system_auth:3" "system_distributed:3" "system_traces:3"; do
  KS="${KS_RF%%:*}"; RF="${KS_RF##*:}"
  echo "   - $KS -> dc1:$RF, dc2:$RF"
  kubectl --context "$CTX1" exec -n "$NS" "$SEED1" -- cqlsh -e \
    "ALTER KEYSPACE $KS WITH replication = {'class':'NetworkTopologyStrategy','dc1':$RF,'dc2':$RF};"
done

echo
echo "== 3. nodetool rebuild em cada nó do dc2 (streaming dc1 -> dc2) =="
for p in $PODS_DC2; do
  echo "   - $p ..."
  kubectl --context "$CTX2" exec -n "$NS" "$p" -- nodetool rebuild -- dc1
done

echo
echo "== 4. Gerador de carga =="
echo "   A carga roda numa instância só, no dc1 — nada a ligar aqui."
echo "   Para a demo de queda de região: make mdc-loadgen-dc2-on"

echo
echo ">> Pronto. Agora AUTO_BOOTSTRAP do dc2 pode voltar para \"true\":"
echo "   edite azure-multidc/dc2/patch-statefulset-rack{1,2}.yaml e reaplique."
