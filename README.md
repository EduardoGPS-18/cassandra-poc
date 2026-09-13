# TP01 — Apache Cassandra em Kubernetes

Setup de um cluster **Apache Cassandra** com **5 nós** e **fator de replicação 3 (RF=3)**,
orquestrado por **Kubernetes** rodando dentro de **Docker** via **kind**
(*Kubernetes IN Docker*). Serve de base para a aplicação de estresse (próximo tópico)
e para as demos de **tolerância a falhas** e **escala** exigidas no TP01.

## Por que essas escolhas (mapeando o enunciado)

O Cassandra é a opção **5 (NoSQL database)** → categoria **middleware**. O que pega nota
é o item 3 do enunciado: instalar em cluster, em nuvem, com **tolerância a falhas**,
usando **contêineres** e **orquestradores**. Este repositório cobre exatamente isso:

| Requisito do TP | Como é atendido aqui |
|---|---|
| Contêineres | Cada nó do k8s é um container Docker (kind); cada nó do Cassandra é um pod |
| Orquestrador | Kubernetes (StatefulSet + Services + PVCs) |
| Cluster / múltiplas instâncias | `replicas: 5` no StatefulSet |
| Tolerância a falhas | RF=3 + `make kill-demo` (derruba nó, anel continua servindo) |
| Escala sem parar | `make scale N=7` (adiciona nós ao anel a quente) |
| Portável p/ nuvem | Manifestos padrão k8s → EKS/GKE só trocando o StorageClass |

## Arquitetura

```
                 Docker Desktop (host macOS)
  ┌───────────────────────────────────────────────────────────┐
  │  kind cluster "sd-cassandra"                                │
  │                                                            │
  │  [control-plane]  [worker-1]   [worker-2]   [worker-3]     │
  │                      │            │            │           │
  │                   pods do Cassandra (StatefulSet, 5 réplicas)│
  │        cassandra-0  cassandra-1  cassandra-2  cassandra-3 ...│
  │            │  gossip  │  gossip   │            │            │
  │            └──────────┴───── anel Cassandra ──┴─── RF=3 ────│
  │                                                            │
  │  Service headless "cassandra"      -> DNS estável / seeds   │
  │  Service "cassandra-client:9042"   -> entrada CQL da app    │
  └───────────────────────────────────────────────────────────┘
```

- **StatefulSet**: identidade estável (`cassandra-0..4`), storage próprio por nó (PVC),
  boot ordenado (um nó por vez).
- **Service headless**: descoberta via DNS; define os **seeds** (`cassandra-0`, `cassandra-1`).
- **Service client**: ponto único `cassandra-client:9042` para a aplicação.
- **Snitch** `GossipingPropertyFileSnitch` + DC `dc1` → permite `NetworkTopologyStrategy` (RF por DC).

## Pré-requisitos

- Docker Desktop **aberto** (recomendado: ≥ 6 GB de RAM em Settings → Resources;
  são 5 pods × ~1 GB).
- `kubectl` (já instalado) e `kind` (instale com `make tools`).

## Como subir (caminho feliz)

```bash
make tools        # instala kind (só na 1ª vez)
make bootstrap    # cria cluster + aplica manifestos + espera + cria keyspace RF=3 + status
```

`make bootstrap` = `preflight → up → deploy → wait → keyspace → status`.
O boot ordenado dos 5 nós leva alguns minutos (cada nó espera o anterior ficar *Ready*).

### Passo a passo (equivalente, para explicar na apresentação)

```bash
make preflight    # confere docker/kind/kubectl e o daemon
make up           # kind create cluster (1 control-plane + 3 workers)
make deploy       # kubectl apply namespace + services + statefulset
make wait         # espera os 5 pods ficarem Ready
make keyspace     # cria keyspace sd_demo com RF=3 + tabela de exemplo
make status       # pods, PVCs e `nodetool status` (esperado: 5 linhas UN)
```

## Comandos úteis

```bash
make status       # anel + pods + PVCs
make cqlsh        # shell CQL interativo no cassandra-0
make kill-demo    # DEMO: derruba 1 nó e mostra o anel resistindo
make scale N=7    # aumenta o anel a quente
make pf           # port-forward 9042 -> localhost (para app local)
make down         # destroi o cluster
```

## Verificando o RF=3

```bash
make cqlsh
# dentro do cqlsh:
DESCRIBE KEYSPACE sd_demo;                 # mostra NetworkTopologyStrategy dc1:3
CONSISTENCY LOCAL_QUORUM;                  # 2 de 3 réplicas bastam
INSERT INTO sd_demo.eventos (bucket, ts, id, payload)
  VALUES (1, toTimestamp(now()), now(), 'oi');
```

Para ver **onde** uma chave é replicada (quais 3 nós):
```bash
kubectl exec -n sd cassandra-0 -- nodetool getendpoints sd_demo eventos 1
```

## Levando para a nuvem (AWS/GCP) — só portabilidade por enquanto

Os manifestos são k8s padrão. Para rodar num cluster gerenciado:

1. Provisione o cluster: **EKS** (`eksctl`) ou **GKE** (`gcloud container clusters create`).
2. No `k8s/cassandra/20-statefulset.yaml`, descomente `storageClassName` no
   `volumeClaimTemplates` e use `gp3` (EKS) ou `pd-ssd`/`premium-rwo` (GKE).
3. Suba a RAM/CPU dos `resources` e a `MAX_HEAP_SIZE` (produção: heap 8G+).
4. Para multi-AZ real, use `topologySpreadConstraints` por zona e mapeie zonas → racks
   no snitch. `make deploy` funciona igual.

## Aplicação de carga + demo de tolerância a falhas

A "aplicação" do TP é um **gerador de carga** (`app/loadgen.py`, Python +
`cassandra-driver`) que dispara escritas/leituras contínuas em `LOCAL_QUORUM`
contra o Service `cassandra-client:9042` e imprime um **placar ao vivo**. O log
dela é o palco da demo: mostra throughput, latência (p50/p95/p99), nós vivos e
detecta em tempo real um nó **caindo** (`HOST DOWN`) e **voltando** (`HOST ADD`).

Subir a app e ver o log:
```bash
make app-up      # build da imagem + kind load + deploy
make app-logs    # placar ao vivo (deixe rodando num terminal)
```

Em outro terminal, provoque a falha:
```bash
make kill-demo                      # CRASH ABRUPTO (sem drain) — cenário do enunciado
MODE=graceful make kill-demo        # saída graciosa (preStop: nodetool drain)
```

### Resultado observado (crash abrupto, com a app rodando)
```
>>> HOST DOWN 10.244.3.3  (nós vivos: 4/5)  <== FALHA DETECTADA
   ...~22s rodando com 4/5 nós: err=0, throughput estável/maior...
>>> HOST REMOVE 10.244.3.3 / HOST ADD 10.244.3.7   (StatefulSet recriou o nó)
   nós_vivos=5/5, err=0
TOTAL ok=479728 err=0
```
**Por que funciona:** RF=3 + `LOCAL_QUORUM` exige 2 de 3 réplicas. Com 1 nó fora,
o coordenador ainda forma quórum → **zero erros, zero downtime**. O `TokenAware`
do driver roteia em volta do nó morto; o StatefulSet recria o pod (dado no PVC) e
ele reingressa sozinho no anel.

> Dica de apresentação: mostre os **dois** cenários. O gracioso (`nodetool drain`)
> tem zero blip mas "esconde" a falha; o abrupto é o que o enunciado pede
> ("máquina cai abruptamente") e evidencia a detecção + recuperação.

## GitOps com Argo CD (entrega contínua)

Em vez de aplicar os manifestos "na mão" com `kubectl apply`, o **Argo CD** segue
o **Git como fonte da verdade**: ele compara o que está no repositório (`k8s/`)
com o que roda no cluster e **sincroniza sozinho** (com `selfHeal` e `prune`).
Mexeu no cluster na unha? O Argo reverte para o Git. Deu commit? O Argo aplica.

> Pré-requisito: o cluster kind já criado (`make up`) e o seu código **num
> repositório Git acessível** (ex.: GitHub público). O Argo lê do Git, não do
> seu disco.

```bash
make argo-install                                   # instala o Argo CD no cluster
make argo-app REPO=https://github.com/<voce>/SD \
              BRANCH=main APP_PATH=tp-01/k8s          # registra a Application
```

- `APP_PATH=tp-01/k8s` se o repositório tem a pasta `tp-01/` na raiz;
  use `APP_PATH=k8s` se você versionou **direto** o conteúdo de `tp-01/`.
- A partir daí, a Application `tp01-cassandra` sincroniza automaticamente: os
  Services + StatefulSet do Cassandra sobem sem nenhum `kubectl apply` seu.

Acompanhar / operar:

```bash
make argo-ui        # port-forward: abra https://localhost:8080
make argo-password  # senha inicial do usuário 'admin'
make argo-sync      # força um sync na hora (sem esperar o poll de ~3 min)
kubectl -n argocd get application tp01-cassandra -w   # estado: Synced/Healthy
make argo-down      # remove o Argo CD e a Application
```

**Como isso mapeia o enunciado:** GitOps é o padrão de *entrega contínua* para
orquestradores — reforça os itens de **orquestração** e **portabilidade p/ nuvem**
(o mesmo fluxo Argo → cluster funciona igual em EKS/GKE, bastando trocar o
`StorageClass`). O `selfHeal` também vira uma segunda camada de **tolerância a
falhas** no nível de configuração: se algo apagar um manifesto, o Argo recria.

## Estrutura

```
tp-01/
├── Makefile                     # ciclo de vida (make help)
├── README.md
├── kind/cluster.yaml            # 1 control-plane + 3 workers
├── app/                         # aplicação de carga (imagem própria)
│   ├── loadgen.py               # gerador de carga + placar + watcher de nós
│   ├── requirements.txt
│   └── Dockerfile               # python:3.11-slim + cassandra-driver
├── k8s/
│   ├── 00-namespace.yaml
│   ├── cassandra/
│   │   ├── 10-service-headless.yaml   # DNS estável / seeds
│   │   ├── 11-service-client.yaml     # entrada CQL da app
│   │   ├── 20-statefulset.yaml        # 5 nós + storage + probes
│   │   └── schema.cql                 # keyspace RF=3 + tabela demo
│   ├── app/
│   │   └── deployment.yaml            # Deployment do gerador de carga
│   └── argocd/                        # GitOps (Argo CD)
│       ├── 00-namespace.yaml          # namespace argocd
│       └── application.yaml           # Application (template) -> sincroniza k8s/
└── scripts/
    ├── preflight.sh
    ├── init-keyspace.sh
    ├── status.sh
    ├── kill-node-demo.sh              # demo de falha (abrupt|graceful)
    ├── argocd-install.sh             # instala o Argo CD no cluster
    └── argocd-app.sh                 # registra a Application no seu repo Git
```
# cassandra-poc
