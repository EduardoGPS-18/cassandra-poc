# Cassandra multi-datacenter na Azure — 2 regiões, 2 racks, 6 nós

Um **único anel Cassandra** distribuído em **duas regiões da Azure**, cada uma
num cluster AKS próprio. Dentro de cada região, os nós se dividem em **dois
racks**, e cada rack é uma **zona de disponibilidade real**.

```
      AKS chilecentral (dc1)                     AKS mexicocentral (dc2)
  ┌──────────────────────────────┐        ┌──────────────────────────────┐
  │ rack1 = zona chilecentral-1   │        │ rack1 = zona mexicocentral-1        │
  │   cassandra-rack1-0  .32.10 ●│        │● .32.10  cassandra-rack1-0   │
  │   cassandra-rack1-1  .32.11 ●│        │● .32.11  cassandra-rack1-1   │
  │ rack2 = zona chilecentral-2   │        │ rack2 = zona mexicocentral-2        │
  │   cassandra-rack2-0  .32.12 ●│        │● .32.12  cassandra-rack2-0   │
  │                              │        │                              │
  │ vnet-dc1 10.10.0.0/16        │        │ vnet-dc2 10.20.0.0/16        │
  └───────────────┬──────────────┘        └──────────────┬───────────────┘
                  │        VNet peering global           │
                  └──────────── gossip :7000 ────────────┘

  ● = internal Load Balancer com IP privado FIXO (o broadcast_address do nó)

  RF = {'dc1': 3, 'dc2': 3}   →  6 cópias de cada linha, 3 por região
  Escrita/leitura em LOCAL_QUORUM → 2 das 3 réplicas LOCAIS, sem cruzar o Atlântico
```

| | Anterior (1 DC) | Agora (2 DCs) |
|---|---|---|
| Nós | 5, todos `dc1`/`rack1` | 6 — 3 por DC, 2 racks por DC |
| Rack | rótulo decorativo | zona de disponibilidade real |
| Clusters k8s | 1 | 2, em regiões diferentes |
| StatefulSets | 1 | 2 por cluster (um por rack) |
| Replicação | `{dc1: 3}` | `{dc1: 3, dc2: 3}` |
| Falha tolerada | 1 nó | 1 nó por DC — ou **uma região inteira** |

> **A carga roda numa instância só.** O gerador de carga sobe apenas no dc1,
> fixado na zona 2 — a zona que hospeda o rack2, com 1 nó. A zona 1 concentra os
> 2 nós do rack1 e, como as réplicas são distribuídas em rodízio entre os racks,
> ela carrega 2 das 3 cópias de cada partição. Manter a aplicação fora dela
> evita disputa de CPU onde o Cassandra mais trabalha — o que importa bastante
> com VMs pequenas. O gerador do dc2 existe no manifesto mas fica em
> `replicas: 0`, ligado sob demanda para a demo de queda de região.
>
> Bônus: escrever de um lado só torna a replicação **observável** — dá para ler
> no dc2 um dado que nunca foi escrito lá e provar que atravessou.

---

## O problema central: gossip entre dois clusters k8s

Um nó Cassandra precisa de um endereço **estável** e **alcançável** por todos os
outros. Dentro de um cluster k8s isso é fácil. Entre dois clusters, não:

- **IP de pod não serve.** Muda a cada restart e, com Azure CNI overlay, só
  existe dentro do próprio cluster — o outro AKS não tem rota para ele.
- **DNS do k8s não serve.** `cassandra-rack1-0.cassandra.sd.svc.cluster.local`
  só resolve dentro do cluster que o criou.

A solução aqui tem três peças:

**1. Um internal Load Balancer por nó, com IP privado fixo.**
Cada pod ganha um `Service type=LoadBalancer` interno, ancorado numa subnet
dedicada (`snet-lb`), com IP escolhido à mão: `10.10.32.10/.11/.12` no dc1 e
`10.20.32.10/.11/.12` no dc2. Esses IPs atravessam o VNet peering e nunca mudam,
mesmo que o pod seja recriado.

**2. `broadcast_address` = IP do LB, `listen_address` = IP do pod.**
O nó escuta no IP do pod mas **anuncia** o IP do LB. É o mesmo padrão que o
`Ec2MultiRegionSnitch` usa com IPs públicos da AWS. Um wrapper em volta do
entrypoint oficial lê o mapa pod→IP do ConfigMap `cassandra-topology` e injeta
o valor certo em cada pod.

Repare numa distinção fácil de errar: `broadcast_rpc_address` (o endereço que os
**drivers** recebem) continua sendo o IP do pod. Os clientes são locais ao
cluster e falam direto com o pod — não faz sentido mandá-los pelo LB.

**3. `prefer_local=true`.**
Sem isso, dois nós do *mesmo* DC também conversariam pelo internal LB — um
hairpin (pod → LB → outro pod do mesmo cluster) que a Azure trata mal, e que
faria cada mensagem de gossip local pagar um salto de LB. Com `prefer_local`, o
`GossipingPropertyFileSnitch` usa o IP do pod dentro do DC e só sai pelo LB
quando o destino está na outra região.

> Tudo isso vive em [`azure-multidc/base/30-statefulset-rack1.yaml`](azure-multidc/base/30-statefulset-rack1.yaml),
> comentado linha a linha.

---

## Passo a passo

### 0. Pré-requisitos

Uma assinatura Azure com crédito — se você é aluno, **Azure for Students** dá
US$100 sem cartão (https://azure.microsoft.com/free/students/).

```bash
brew install azure-cli     # o kubectl você já tem
make az-login              # abre o navegador e mostra a subscription ativa
```

Se houver mais de uma assinatura:

```bash
az account list -o table
az account set --subscription "<nome ou id>"
```

> **Docker não é necessário.** A imagem do `loadgen` é compilada *dentro* da
> Azure (ACR Tasks), o que também resolve a arquitetura: seu Mac é `arm64` e os
> nós do AKS são `amd64` — um `docker build` local geraria uma imagem que os nós
> não conseguem executar (`exec format error`).

> **Assinatura Azure for Students tem limites duros.** Três que mordem aqui:
> só cinco regiões são liberadas por policy (`chilecentral`, `mexicocentral`,
> `spaincentral`, `belgiumcentral`, `italynorth`); o teto é de **6 vCPUs por
> região**; e a família `DSv5` tem cota **zero**. Por isso o setup usa
> `Standard_B2s_v2` (3 × 2 vCPU = 6, exato) e a região padrão é o Chile.
>
> A série B é *burstable*: entrega CPU plena enquanto há crédito e cai para uma
> fração dele quando acaba. Não é a VM que se escolheria para Cassandra — é a
> que cabe. Para compensar, o loadgen sobe com `CONCURRENCY=4` em vez de 32. Se
> ainda assim algum nó ficar `NotReady` no meio da demo, pause o loadgen
> (`kubectl scale deploy/loadgen --replicas=0`) e espere o crédito recuperar.

### 1. Grupos, registry e rede

```bash
make mdc-rg        # 2 resource groups, um por região
make mdc-acr       # 1 ACR compartilhado
make mdc-net       # 2 VNets + subnets + peering global (deve sair "Connected")
```

### 2. Os dois clusters AKS

```bash
make mdc-clusters  # ~10 min (5 por cluster)
```

Cada cluster nasce com `--zones 1 2` e 3 nós → **2 VMs na zona 1, 1 VM na zona
2**, exatamente a forma da topologia de racks. O script termina imprimindo a
zona de cada nó; confira antes de seguir.

Ele também concede **Network Contributor** à identidade de cada cluster sobre a
sua VNet — sem isso o AKS não consegue criar os frontends de LB na `snet-lb` e
os Services ficam `<pending>` para sempre.

### 3. Imagem da aplicação

```bash
make mdc-image     # az acr build: compila na Azure, em linux/amd64
```

### 4. Sobe o dc1 e cria o keyspace

```bash
make mdc-deploy-dc1
make mdc-keyspace    # RF = {dc1: 3} — o dc2 ainda não existe no anel
```

Confira que os 3 nós formaram anel antes de seguir:

```bash
kubectl --context aks-tp01-dc1 exec -n sd cassandra-rack1-0 -- nodetool status
```

Esperado: 3 linhas `UN`, coluna `Rack` mostrando `rack1`, `rack1`, `rack2`.

### 5. Sobe o dc2

```bash
make mdc-deploy-dc2
```

Os nós do dc2 sobem com **`auto_bootstrap: false`** — eles entram no anel sem
puxar dados. É o procedimento oficial para adicionar um DC: streamar durante o
join, atravessando regiões, é lento e frágil. O gerador de carga do dc2 sobe com
`replicas: 0` pelo mesmo motivo.

### 6. Junta os dois DCs

```bash
make mdc-join
```

Esse é o passo que **faz o cluster virar multi-DC de fato**:

1. verifica que os 6 nós se enxergam (gossip cruzou o peering);
2. `ALTER KEYSPACE ... {'dc1':3, 'dc2':3}` — em `sd_demo` e nos keyspaces de
   sistema (`system_auth`, `system_distributed`, `system_traces`);
3. `nodetool rebuild -- dc1` em cada nó do dc2 — puxa do Brasil os dados que
   agora lhe pertencem. **Sem este passo o dc2 fica no anel mas vazio**, e
   leituras `LOCAL_QUORUM` no dc2 devolveriam dados faltando;
4. (o gerador de carga não é tocado — roda numa instância só, no dc1)

### 7. Confere

```bash
make mdc-status
```

Você deve ver 6 linhas `UN` divididas em dois blocos `Datacenter: dc1` e
`Datacenter: dc2`, com as colunas `Rack` mostrando `rack1`/`rack2`. E a prova
final da topologia:

```bash
kubectl --context aks-tp01-dc1 exec -n sd cassandra-rack1-0 -- \
  nodetool getendpoints sd_demo eventos 1
```

Seis endereços — três de `10.10.32.x` e três de `10.20.32.x`. A mesma linha
existe nas duas regiões e, dentro de cada uma, em dois racks/zonas diferentes.

### Atalho

```bash
make mdc-bootstrap   # todos os passos acima em sequência
```

---

## Demos

**Perda de um nó** (RF=3 local, `LOCAL_QUORUM` = 2 de 3 → zero erro):

```bash
make mdc-logs-dc1                 # terminal 1: placar ao vivo
make mdc-kill-dc1 N=1             # terminal 2
```

**Perda de um rack inteiro = perda de uma zona de disponibilidade.** Como rack2
tem 1 nó e rack1 tem 2, derrubar o rack2 do dc1 deixa toda partição com 2 das 3
réplicas locais vivas — ainda há quórum local:

```bash
kubectl --context aks-tp01-dc1 -n sd scale sts/cassandra-rack2 --replicas=0
```

**Perda de uma região inteira** — a demo que só o multi-DC permite. A carga roda
numa instância só, no dc1, então aqui você precisa ligar a do dc2 antes: é ela
que vai provar que aquela região continua servindo sozinha.

```bash
make mdc-loadgen-dc2-on     # sobe o gerador de carga no dc2
make mdc-logs-dc2           # terminal 1
```

Em outro terminal, derrube o dc1 inteiro:

```bash
kubectl --context aks-tp01-dc1 -n sd scale sts/cassandra-rack1 --replicas=0
kubectl --context aks-tp01-dc1 -n sd scale sts/cassandra-rack2 --replicas=0
```

Ao terminar: `make mdc-loadgen-dc2-off`.

O loadgen do dc2 não registra um único erro: ele nunca dependeu do dc1, porque
`LOCAL_QUORUM` só conta réplicas locais. Ao religar o dc1, o *hinted handoff* e
o `nodetool repair` reconciliam o que ficou para trás.

> Para a apresentação, o contraste vale ouro: `LOCAL_QUORUM` sobrevive à queda de
> uma região; `QUORUM` (4 de 6, global) não sobreviveria — pararia junto. Dá para
> demonstrar mudando `CONSISTENCY` no Deployment do loadgen.

---

## GitOps: um Argo CD governando as duas regiões

Modelo **hub-and-spoke**: o Argo CD roda só no cluster do dc1 e administra os
dois. O dc2 entra como um *destino remoto* — o Argo fala com a API pública do
AKS de lá usando um token de ServiceAccount.

```bash
make set-acr ACR=<seu-acr>          # grava o registry real nos overlays
git add azure-multidc && git commit -m "chore: aponta overlays para o ACR" && git push

make mdc-argo-bootstrap REPO=https://github.com/EduardoGPS-18/cassandra-poc
```

O `mdc-argo-bootstrap` encadeia três passos, que você também pode rodar soltos:

| Alvo | O que faz |
|---|---|
| `mdc-argo-install` | Instala o Argo CD no cluster do dc1 |
| `mdc-argo-register-dc2` | Cria no dc2 uma ServiceAccount `argocd-manager` com token, e grava esse token como um Secret de cluster no Argo do dc1 |
| `mdc-argo-apps` | Registra `tp01-cassandra-dc1` (in-cluster) e `tp01-cassandra-dc2` (destino remoto) |

Acompanhar e operar:

```bash
make mdc-argo-status     # Sync/Health das 2 Applications + clusters registrados
make mdc-argo-ui         # https://localhost:8080
make mdc-argo-password
make mdc-argo-sync       # força sync das duas, sem esperar o poll de ~3 min
make mdc-argo-down       # desfaz tudo, inclusive a SA criada no dc2
```

O registro do cluster remoto é feito **sem a CLI do Argo**: o
`scripts/argocd-register-cluster.sh` monta na mão o Secret com label
`argocd.argoproj.io/secret-type: cluster` que o `argocd cluster add` criaria.
Evita instalar a CLI e fazer login só para um passo — e deixa visível o que o
comando mágico realmente faz.

### Três armadilhas que o setup já trata

**O loadgen do dc2 seria desligado pelo selfHeal.** No Git ele está com
`replicas: 0` (proposital, até o rebuild terminar), e o `make mdc-join` o liga
para 1. Com `selfHeal` ativo, o Argo reverteria isso em minutos. Por isso a
Application do dc2 tem `ignoreDifferences` em `/spec/replicas` do Deployment.

**`volumeClaimTemplates` é imutável.** O cluster preenche defaults (`volumeMode`,
`persistentVolumeClaimRetentionPolicy`) que o Argo tenta remover eternamente,
deixando a Application OutOfSync para sempre. Ignorado nos dois StatefulSets.

**A demo de queda de região briga com o selfHeal.** Se você fizer
`kubectl scale sts/cassandra-rack1 --replicas=0` para simular a perda do dc1, o
Argo vai restaurar em até ~3 minutos — o que é, aliás, uma boa demonstração de
self-healing, se você avisar a plateia. Para a demo de falha propriamente dita,
prefira `make mdc-kill-dc1`: apagar um pod não muda o manifesto, então quem
recria é o próprio StatefulSet e o Argo nem se envolve. Se quiser mesmo derrubar
um rack inteiro com o Argo ligado, suspenda o automatismo antes:

```bash
kubectl --context aks-tp01-dc1 -n argocd patch application tp01-cassandra-dc1 \
  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

> Se os clusters AKS fossem **privados** (`--enable-private-cluster`), a API do
> dc2 não teria endereço público e o Argo do dc1 só a alcançaria pelo peering,
> com Private DNS resolvendo o FQDN dos dois lados. Aqui os clusters são
> públicos, então o registro funciona direto.

## Custo e teardown

São **2 clusters AKS** (6 VMs no total), 6 discos Premium, 6 frontends de
internal LB e tráfego entre regiões. A ordem de grandeza é de **~US$0,70–0,90
por hora**, além do egress Chile↔México gerado pela replicação contínua — o
loadgen escreve sem parar, e cada escrita atravessa o Atlântico.

```bash
make mdc-down     # apaga os 2 resource groups inteiros
az group list -o table
```

Rodando só o necessário para gravar a demo, o custo fica em poucos dólares.
Deixado ligado, some com o crédito de estudante em dias.

---

## Problemas comuns

| Sintoma | Causa / solução |
|---|---|
| Services `cassandra-rack*-*` presos em `<pending>` | A identidade do AKS não tem permissão na VNet. Rode a parte final de `scripts/azure-multidc-clusters.sh` (role assignment de Network Contributor). |
| `nodetool status` só mostra 3 nós | Gossip não cruzou. Confira `az network vnet peering list` (deve estar `Connected`) e se a porta 7000 é permitida entre `10.10.32.0/24` e `10.20.32.0/24`. |
| Pods `Pending` com `node(s) didn't match node affinity` | A zona esperada não existe nesse cluster. Cheque os nomes reais (`kubectl get nodes -L topology.kubernetes.io/zone`) e ajuste `values:` em `azure-multidc/<dc>/patch-statefulset-rack*.yaml`. |
| `ERRO: nenhum IP de internal LB mapeado para ...` | O ConfigMap `cassandra-topology` não tem uma linha para esse pod. Se você escalou um rack, adicione o pod ao `lb-ips` **e** crie o Service correspondente. |
| IP do LB saiu diferente do pedido | Alguma versão do cloud-provider ignora a anotação `azure-load-balancer-ipv4`. Os manifestos também setam `spec.loadBalancerIP` com o mesmo valor; se ainda assim divergir, ajuste o `lb-ips` para o IP que a Azure atribuiu. |
| Leituras no dc2 devolvem menos dados | Faltou o `nodetool rebuild`. Rode `make mdc-join` de novo (é idempotente). |
| `SkuNotAvailable` no `az aks create` | A região não tem a VM ou falta cota. Tente `MDC_VM=Standard_D2s_v3` ou troque `MDC_LOC1`/`MDC_LOC2`. |
| `exec format error` no loadgen | Imagem buildada em arm64. Use `make mdc-image` (ACR Tasks, `--platform linux/amd64`), não `docker build` no Mac. |
| `ImagePullBackOff` no loadgen | ACR não anexado ao cluster: `az aks update -g <rg> -n <aks> --attach-acr <acr>`. |
| PVC `Pending` | StorageClass inexistente. Confira `kubectl get storageclass` — no AKS devem existir `managed-csi` e `managed-csi-premium`. |
| Nó Cassandra `NotReady` sob carga | Crédito de CPU da VM burstable esgotado. Baixe `CONCURRENCY` no loadgen ou pause-o entre as demos. |

---

## Escala e limites deste desenho

**Escalar um rack não é mais um `kubectl scale`.** Cada nó depende de um Service
de LB com IP fixo e de uma entrada no ConfigMap. Para adicionar um nó ao rack1
do dc1: acrescente `cassandra-rack1-2=10.10.32.13` ao `lb-ips`, crie o Service
correspondente em `patch-services-lb.yaml`, suba `replicas` para 3 e reaplique.
É o preço de ter endereços estáveis entre clusters — a alternativa (descobrir o
IP do próprio LB via API do k8s num initContainer) troca esse trabalho manual
por RBAC e mais partes móveis.

**Depois do rebuild, volte `AUTO_BOOTSTRAP` para `"true"` no dc2**
(`azure-multidc/dc2/patch-statefulset-rack*.yaml`) e reaplique. Com `false`
permanente, um pod recriado no futuro subiria vazio e sem streamar.

**Nada disto foi executado contra uma assinatura Azure real.** Os manifestos
foram validados por renderização (`make mdc-render-dc1`), e os scripts por
checagem de sintaxe. A primeira execução de ponta a ponta é sua — os pontos mais
prováveis de atrito estão na tabela de problemas acima, em ordem de frequência.
