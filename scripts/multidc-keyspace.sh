#!/usr/bin/env bash
# Cria o keyspace no dc1 (ainda sem o dc2 — ver comentário no schema.cql).
set -euo pipefail
NS="${NS:-sd}"
CTX="${CTX:?defina CTX com o contexto kubectl do dc1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POD="${POD:-cassandra-rack1-0}"

echo ">> Aplicando schema em $CTX / $POD"
kubectl --context "$CTX" exec -i -n "$NS" "$POD" -- cqlsh < "$DIR/azure-multidc/schema.cql"

kubectl --context "$CTX" exec -n "$NS" "$POD" -- cqlsh -e \
  "SELECT keyspace_name, replication FROM system_schema.keyspaces WHERE keyspace_name='sd_demo';"
