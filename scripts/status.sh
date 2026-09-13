#!/usr/bin/env bash
# Visão rápida do anel + pods + PVCs.
set -euo pipefail
NS="${NS:-sd}"

echo "== Pods =="
kubectl get pods -n "$NS" -o wide

echo
echo "== PVCs (storage por nó) =="
kubectl get pvc -n "$NS"

echo
echo "== nodetool status (o anel) =="
# UN = Up/Normal. Esperamos 5 linhas UN quando o cluster estiver saudável.
kubectl exec -n "$NS" cassandra-0 -- nodetool status
