-- Schema de demonstração do TP01.
--
-- RF=3 (requisito): usamos NetworkTopologyStrategy com 3 réplicas no dc1.
-- Como temos 5 nós e RF=3, CADA linha vive em 3 dos 5 nós. Isso permite:
--   - perder 1 nó e manter QUORUM (2 de 3) em leitura/escrita  -> tolerância a falhas
--   - LOCAL_QUORUM continua atendendo mesmo com 1 réplica fora do ar
CREATE KEYSPACE IF NOT EXISTS sd_demo
  WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3};

USE sd_demo;

-- Tabela simples de exemplo (a aplicação real vem depois).
-- Modelagem por partition key (id) — típico do Cassandra.
CREATE TABLE IF NOT EXISTS eventos (
    id        uuid,
    bucket    int,
    ts        timestamp,
    payload   text,
    PRIMARY KEY ((bucket), ts, id)
) WITH CLUSTERING ORDER BY (ts DESC);
