#!/usr/bin/env bash
# Cria o keyspace RF=3 e o schema de demo, injetando o schema.cql no cassandra-0.
set -euo pipefail
NS="${NS:-sd}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ">> Aplicando schema (RF=3) via cassandra-0..."
# cqlsh lê os comandos do STDIN (usar -f /dev/stdin falha: stream não é seekable).
kubectl exec -i -n "$NS" cassandra-0 -- cqlsh < "$DIR/k8s/cassandra/schema.cql"

echo ">> Keyspaces:"
kubectl exec -n "$NS" cassandra-0 -- cqlsh -e "DESCRIBE KEYSPACES;"

echo ">> Fator de replicação de sd_demo:"
kubectl exec -n "$NS" cassandra-0 -- cqlsh -e \
  "SELECT keyspace_name, replication FROM system_schema.keyspaces WHERE keyspace_name='sd_demo';"
