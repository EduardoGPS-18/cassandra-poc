-- Schema inicial do cluster multi-DC.
--
-- Nasce com réplicas SÓ no dc1: neste momento o dc2 ainda não existe no anel.
-- Declarar 'dc2': 3 agora faria o coordenador tentar satisfazer réplicas em um
-- DC vazio. O dc2 entra depois, via ALTER + nodetool rebuild
-- (scripts/multidc-join-dc2.sh) — que é o procedimento oficial do Cassandra
-- para adicionar um datacenter a um cluster existente.
CREATE KEYSPACE IF NOT EXISTS sd_demo
  WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': 3};

USE sd_demo;

CREATE TABLE IF NOT EXISTS eventos (
    id        uuid,
    bucket    int,
    ts        timestamp,
    payload   text,
    PRIMARY KEY ((bucket), ts, id)
) WITH CLUSTERING ORDER BY (ts DESC)
  -- gc_grace_seconds: quanto tempo as TOMBSTONES (marcas de DELETE) sobrevivem
  -- antes de a compactacao poder descarta-las. O default sao 10 DIAS, para dar
  -- tempo de um no ausente receber o hint da remocao e nao "ressuscitar" a linha.
  --
  -- Com o gerador de carga fazendo 25% de DELETE, 10 dias e inviavel: as
  -- tombstones se acumulam nas mesmas 64 particoes e o SELECT (que varre do ts
  -- mais novo para tras) passa a pular montanhas delas -> latencia de leitura
  -- sobe e, em execucao longa, estoura em TombstoneOverwhelmingException.
  --
  -- 1 hora e folgado para a janela de uma demo e curto o bastante para a
  -- compactacao limpar durante a sessao.
  AND gc_grace_seconds = 3600;
