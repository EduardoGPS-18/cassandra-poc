#!/usr/bin/env bash
# Visão do cluster inteiro, dos dois lados.
set -euo pipefail
NS="${NS:-sd}"
CTX1="${CTX1:?}"; CTX2="${CTX2:?}"

for ctx in "$CTX1" "$CTX2"; do
  echo "================ $ctx ================"
  kubectl --context "$ctx" get pods -n "$NS" -o wide
  echo
  echo "-- IPs fixos de gossip (internal LB) --"
  kubectl --context "$ctx" get svc -n "$NS" -l role=gossip-endpoint \
    -o custom-columns='SERVICE:.metadata.name,IP-LB:.status.loadBalancer.ingress[0].ip'
  echo
done

echo "================ anel completo (visto do dc1) ================"
# Datacenter / Rack aparecem aqui: é a prova visual da topologia.
kubectl --context "$CTX1" exec -n "$NS" cassandra-rack1-0 -- nodetool status

echo
echo "================ onde vive a partição bucket=1 ================"
kubectl --context "$CTX1" exec -n "$NS" cassandra-rack1-0 -- \
  nodetool getendpoints sd_demo eventos 1
