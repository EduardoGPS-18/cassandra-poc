# TP01 - Apache Cassandra em Kubernetes (kind) — atalhos do ciclo de vida.
# Uso: `make help`
NS      ?= sd
CLUSTER ?= sd-cassandra
KUBECONFIG_CTX = kind-$(CLUSTER)

.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help tools preflight up deploy wait keyspace status cqlsh pf kill-demo test scale down clean bootstrap \
        app-build app-load app-deploy app-up app-logs app-restart app-down \
        argo-install argo-app argo-ui argo-password argo-sync argo-down \
        mdc-providers mdc-rg mdc-acr mdc-net mdc-clusters mdc-image mdc-render-dc1 mdc-render-dc2 mdc-deploy-dc1 \
        mdc-deploy-dc2 mdc-keyspace mdc-join mdc-status mdc-logs-dc1 mdc-logs-dc2 mdc-kill-dc1 \
        mdc-kill-dc2 mdc-loadgen-dc2-on mdc-loadgen-dc2-off mdc-stop mdc-start \
        mdc-power mdc-fix-commitlog mdc-bootstrap mdc-down \
        az-login set-acr \
        mdc-argo-install mdc-argo-register-dc2 mdc-argo-apps mdc-argo-bootstrap mdc-argo-ui \
        mdc-argo-password mdc-argo-status mdc-argo-sync mdc-argo-down \
        mdc-argo-expose mdc-argo-unexpose

help: ## Mostra esta ajuda
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

tools: ## Instala o kind via Homebrew (kubectl/docker você já tem)
	@command -v kind >/dev/null 2>&1 || brew install kind
	@echo "kind: $$(kind version)"

preflight: ## Confere docker/kind/kubectl e o daemon do Docker
	@bash scripts/preflight.sh

up: ## Cria o cluster kind (1 control-plane + 3 workers)
	kind create cluster --config kind/cluster.yaml
	kubectl cluster-info --context $(KUBECONFIG_CTX)

deploy: ## Aplica namespace + services + StatefulSet do Cassandra
	kubectl apply -f k8s/00-namespace.yaml
	kubectl apply -f k8s/cassandra/

wait: ## Espera os 5 nós ficarem Ready (pode levar ~8 min no boot ordenado)
	kubectl -n $(NS) rollout status statefulset/cassandra --timeout=900s

keyspace: ## Cria o keyspace RF=3 e o schema de demo
	@bash scripts/init-keyspace.sh

status: ## Mostra pods, PVCs e o anel (nodetool status)
	@bash scripts/status.sh

cqlsh: ## Abre um cqlsh interativo no cassandra-0
	kubectl exec -it -n $(NS) cassandra-0 -- cqlsh

pf: ## Port-forward do CQL (9042) para localhost (para a app local depois)
	kubectl -n $(NS) port-forward svc/cassandra-client 9042:9042

kill-demo: ## Derruba nó(s): make kill-demo N=2 MODE=abrupt (ou MODE=graceful)
	@COUNT=$(or $(N),1) MODE=$(or $(MODE),abrupt) HOLD=$(or $(HOLD),0) bash scripts/kill-node-demo.sh

test: ## Teste automatizado de falha: make test N=2 MODE=abrupt WINDOW=30
	@N=$(or $(N),1) MODE=$(or $(MODE),abrupt) WINDOW=$(or $(WINDOW),30) bash scripts/run-test.sh

scale: ## Escala o anel: make scale N=7  (aumentar cluster sem parar o serviço)
	kubectl -n $(NS) scale statefulset/cassandra --replicas=$(N)
	kubectl -n $(NS) rollout status statefulset/cassandra --timeout=900s

bootstrap: preflight up deploy wait keyspace status ## Faz TUDO de ponta a ponta

# ---- Aplicação de carga (demo de tolerância a falhas) --------------------- #
app-build: ## Builda a imagem do gerador de carga
	docker build -t tp01-loadgen:latest app

app-load: ## Carrega a imagem no cluster kind (kind não usa o registry local)
	kind load docker-image tp01-loadgen:latest --name $(CLUSTER)

app-deploy: ## Aplica o Deployment da app
	kubectl apply -f k8s/app/deployment.yaml
	kubectl -n $(NS) rollout status deploy/loadgen --timeout=180s

app-up: app-build app-load app-deploy ## build + load + deploy da app

app-logs: ## Segue o log da app (placar ao vivo — palco da demo de falha)
	kubectl logs -n $(NS) -l app=loadgen -f --prefix | grep --line-buffered -v '#LAT'

app-restart: ## Reinicia a app (recarrega config)
	kubectl -n $(NS) rollout restart deploy/loadgen

app-down: ## Remove a app
	kubectl delete -f k8s/app/deployment.yaml --ignore-not-found

# ---- GitOps com Argo CD --------------------------------------------------- #
argo-install: ## Instala o Argo CD no cluster kind e espera ficar Ready
	@bash scripts/argocd-install.sh

argo-app: ## Registra a Application: make argo-app REPO=https://github.com/<voce>/SD [BRANCH=main] [APP_PATH=tp-01/k8s]
	@REPO="$(REPO)" BRANCH="$(or $(BRANCH),main)" APP_PATH="$(or $(APP_PATH),k8s)" bash scripts/argocd-app.sh

argo-sync: ## Força um sync imediato da Application (sem esperar o poll)
	kubectl -n argocd patch application tp01-cassandra --type merge \
	  -p '{"operation":{"initiatedBy":{"username":"make"},"sync":{"revision":"HEAD"}}}'

argo-ui: ## Port-forward da UI do Argo CD -> https://localhost:8080
	@echo "UI: https://localhost:8080  (usuário: admin — senha: make argo-password)"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

argo-password: ## Mostra a senha inicial do usuário admin do Argo CD
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

argo-down: ## Remove o Argo CD (Application + componentes + namespace)
	kubectl delete application tp01-cassandra -n argocd --ignore-not-found
	kubectl delete namespace argocd --ignore-not-found

# ---- Azure MULTI-DC: 2 clusters AKS, 2 regioes, 6 nos Cassandra ----------- #
# Topologia: dc1 (brazilsouth) rack1x2 + rack2x1 | dc2 (eastus) rack1x2 + rack2x1
#            rack == zona de disponibilidade.  RF = {dc1:3, dc2:3}
# Guia completo: MULTIDC.md
az-login: ## Autentica na Azure e mostra a subscription ativa
	az login
	az account show -o table

MDC_RG1  ?= rg-tp01-dc1
MDC_LOC1 ?= chilecentral
MDC_AKS1 ?= aks-tp01-dc1
MDC_RG2  ?= rg-tp01-dc2
MDC_LOC2 ?= mexicocentral
MDC_AKS2 ?= aks-tp01-dc2
# Nome do ACR: GLOBALMENTE unico, so minusculas e numeros, 5-50 chars.
#
# NAO REUSE um nome que ja existiu em OUTRA regiao. O nome vira um CNAME
# (<nome>.azurecr.io -> <regiao>.fe.azcr.io) e, ao recriar o registro noutra
# regiao, o CNAME antigo continua apontando para a regiao velha por horas. O
# sintoma e um `az acr login` falhando com CONNECTIVITY_CHALLENGE_ERROR /
# "did not issue a challenge", porque o endpoint atingido nao hospeda mais esse
# registro. Nome novo nasce com o CNAME certo na hora.
MDC_ACR  ?= acrtp01$(shell whoami | tr -cd '[:alnum:]' | tr 'A-Z' 'a-z')mx
# Standard_B2s_v2 (2 vCPU / 8 GiB): NAO e escolha de gosto. A subscription
# Azure for Students tem teto de 6 vCPUs por regiao e cota ZERO na familia
# DSv5. A familia Bsv2 permite 10 vCPUs, entao 3 x B2s_v2 = 6 cabe exato.
# Custo: e burstable (ver MULTIDC.md).
MDC_VM   ?= Standard_B2s_v2
# Regiao do ACR: NAO acompanha a do dc1. O `az acr build` (ACR Tasks) so roda
# num subconjunto de regioes, e chilecentral nao esta nele. mexicocentral esta,
# e e permitida pela policy da subscription. O registro serve as duas regioes
# igualmente; a regiao dele so afeta latencia do pull, que e irrelevante aqui.
# Conferir a lista: o erro do `az acr build` imprime as regioes suportadas.
MDC_ACR_LOC ?= mexicocentral
MDC_TAG  ?= v1
# Zonas usadas em cada regiao (2 zonas: uma por rack). Variam por regiao E por
# subscription — ver comentario em scripts/azure-multidc-clusters.sh.
MDC_ZONES1 ?= 1 2
MDC_ZONES2 ?= 2 3
# Os contextos kubectl recebem o nome do cluster.
MDC_CTX1 = $(MDC_AKS1)
MDC_CTX2 = $(MDC_AKS2)

MDC_ENV = RG1=$(MDC_RG1) LOC1=$(MDC_LOC1) AKS1=$(MDC_AKS1) \
          RG2=$(MDC_RG2) LOC2=$(MDC_LOC2) AKS2=$(MDC_AKS2) \
          ACR=$(MDC_ACR) ACR_RG=$(MDC_RG1) VM=$(MDC_VM) \
          ZONES1="$(MDC_ZONES1)" ZONES2="$(MDC_ZONES2)"

# Renderiza um overlay trocando o placeholder do registry pelo ACR real.
define mdc_render
kubectl kustomize azure-multidc/$(1) \
  | sed -e 's|REGISTRY_PLACEHOLDER|$(MDC_ACR).azurecr.io|g' \
        -e 's|tp01-loadgen:v1|tp01-loadgen:$(MDC_TAG)|g'
endef

mdc-providers: ## [multi-DC] Registra os resource providers na subscription (1a vez)
	@bash scripts/azure-providers.sh

mdc-rg: ## [multi-DC] Cria os 2 resource groups (um por regiao)
	az group create -n $(MDC_RG1) -l $(MDC_LOC1) -o table
	az group create -n $(MDC_RG2) -l $(MDC_LOC2) -o table

mdc-acr: ## [multi-DC] Cria o ACR compartilhado pelos 2 clusters
	# -l explicito: sem ele o ACR herdaria a regiao do resource group (dc1), onde
	# o ACR Tasks nao roda. Ver MDC_ACR_LOC acima.
	az acr create -g $(MDC_RG1) -n $(MDC_ACR) -l $(MDC_ACR_LOC) --sku Basic -o table

mdc-net: ## [multi-DC] Cria as 2 VNets, subnets e o peering global
	@$(MDC_ENV) bash scripts/azure-multidc-net.sh

mdc-clusters: ## [multi-DC] Cria os 2 AKS, concede acesso as subnets e baixa os kubeconfigs
	@$(MDC_ENV) bash scripts/azure-multidc-clusters.sh

mdc-image: ## [multi-DC] Builda a imagem do loadgen localmente e publica no ACR
	# Por que build LOCAL e nao `az acr build`: o ACR Tasks (build server-side)
	# esta bloqueado nesta subscription — Azure for Students nao libera Tasks
	# (erro TasksOperationsNotAllowed). O registro em si funciona normalmente.
	#
	# --platform linux/amd64 e obrigatorio: este Mac e arm64 e os nos do AKS sao
	# amd64. Sem isso os pods morrem com "exec format error". O Docker Desktop
	# emula amd64 via QEMU; como o cassandra-driver tem wheel pronta para
	# manylinux x86_64, nada e compilado e o build sai em poucos minutos.
	az acr login --name $(MDC_ACR)
	docker buildx build --platform linux/amd64 \
	  -t $(MDC_ACR).azurecr.io/tp01-loadgen:$(MDC_TAG) --push app

mdc-render-dc1: ## [multi-DC] Mostra o YAML final do dc1
	@$(call mdc_render,dc1)

mdc-render-dc2: ## [multi-DC] Mostra o YAML final do dc2
	@$(call mdc_render,dc2)

mdc-deploy-dc1: ## [multi-DC] Aplica o dc1 e espera os 3 nos
	@$(call mdc_render,dc1) | kubectl --context $(MDC_CTX1) apply -f -
	kubectl --context $(MDC_CTX1) -n $(NS) rollout status sts/cassandra-rack1 --timeout=900s
	kubectl --context $(MDC_CTX1) -n $(NS) rollout status sts/cassandra-rack2 --timeout=900s

mdc-deploy-dc2: ## [multi-DC] Aplica o dc2 e espera os 3 nos entrarem no anel
	@$(call mdc_render,dc2) | kubectl --context $(MDC_CTX2) apply -f -
	kubectl --context $(MDC_CTX2) -n $(NS) rollout status sts/cassandra-rack1 --timeout=900s
	kubectl --context $(MDC_CTX2) -n $(NS) rollout status sts/cassandra-rack2 --timeout=900s

mdc-keyspace: ## [multi-DC] Cria o keyspace no dc1 (RF dc1:3)
	@CTX=$(MDC_CTX1) bash scripts/multidc-keyspace.sh

mdc-join: ## [multi-DC] Adiciona o dc2 ao keyspace: ALTER + nodetool rebuild
	@CTX1=$(MDC_CTX1) CTX2=$(MDC_CTX2) bash scripts/multidc-join-dc2.sh

mdc-status: ## [multi-DC] Pods, IPs de gossip e o anel completo (6 nos, 2 DCs)
	@CTX1=$(MDC_CTX1) CTX2=$(MDC_CTX2) bash scripts/multidc-status.sh

mdc-logs-dc1: ## [multi-DC] Placar ao vivo do gerador de carga do dc1
	kubectl --context $(MDC_CTX1) logs -n $(NS) -l app=loadgen -f --prefix | grep --line-buffered -v '\#LAT'

mdc-logs-dc2: ## [multi-DC] Placar ao vivo do gerador de carga do dc2
	kubectl --context $(MDC_CTX2) logs -n $(NS) -l app=loadgen -f --prefix | grep --line-buffered -v '\#LAT'

mdc-loadgen-dc2-on: ## [multi-DC] Liga o gerador de carga do dc2 (demo de queda de regiao)
	kubectl --context $(MDC_CTX2) -n $(NS) scale deploy/loadgen --replicas=1
	kubectl --context $(MDC_CTX2) -n $(NS) rollout status deploy/loadgen --timeout=180s

mdc-loadgen-dc2-off: ## [multi-DC] Desliga o gerador de carga do dc2
	kubectl --context $(MDC_CTX2) -n $(NS) scale deploy/loadgen --replicas=0

mdc-kill-dc1: ## [multi-DC] Derruba no(s) do dc1: make mdc-kill-dc1 N=1 [HOLD=30] [MODE=abrupt]
	@CTX=$(MDC_CTX1) COUNT=$(or $(N),1) MODE=$(or $(MODE),abrupt) HOLD=$(or $(HOLD),0) bash scripts/kill-node-demo.sh

mdc-kill-dc2: ## [multi-DC] Derruba no(s) do dc2
	@CTX=$(MDC_CTX2) COUNT=$(or $(N),1) MODE=$(or $(MODE),abrupt) HOLD=$(or $(HOLD),0) bash scripts/kill-node-demo.sh

mdc-bootstrap: mdc-providers mdc-rg mdc-acr mdc-net mdc-clusters mdc-image mdc-deploy-dc1 mdc-keyspace mdc-deploy-dc2 mdc-join mdc-status ## [multi-DC] Tudo de ponta a ponta

mdc-fix-commitlog: ## [multi-DC] Recupera no em CrashLoop por commit log corrompido: make mdc-fix-commitlog CTX=<ctx> POD=<pod>
	@CTX="$(CTX)" POD="$(POD)" NS=$(NS) bash scripts/multidc-fix-commitlog.sh

mdc-stop: ## [multi-DC] Desliga as VMs dos 2 clusters (para de pagar computacao, nao apaga nada)
	@RG1=$(MDC_RG1) AKS1=$(MDC_AKS1) RG2=$(MDC_RG2) AKS2=$(MDC_AKS2) \
	  CTX1=$(MDC_CTX1) CTX2=$(MDC_CTX2) NS=$(NS) bash scripts/azure-multidc-power.sh stop

mdc-start: ## [multi-DC] Religa os 2 clusters e espera o anel voltar (~20 min)
	@RG1=$(MDC_RG1) AKS1=$(MDC_AKS1) RG2=$(MDC_RG2) AKS2=$(MDC_AKS2) \
	  CTX1=$(MDC_CTX1) CTX2=$(MDC_CTX2) NS=$(NS) bash scripts/azure-multidc-power.sh start

mdc-power: ## [multi-DC] Mostra se os clusters estao Running ou Stopped
	@for p in "$(MDC_RG1) $(MDC_AKS1)" "$(MDC_RG2) $(MDC_AKS2)"; do \
	  set -- $$p; \
	  printf "  %-16s power=%-9s provisioning=%s\n" "$$2" \
	    "$$(az aks show -g $$1 -n $$2 --query powerState.code -o tsv)" \
	    "$$(az aks show -g $$1 -n $$2 --query provisioningState -o tsv)"; \
	done

mdc-down: ## [multi-DC] APAGA os 2 resource groups (clusters, ACR, discos, LBs, VNets)
	az group delete -n $(MDC_RG1) --yes --no-wait
	az group delete -n $(MDC_RG2) --yes --no-wait
	@echo ">> Delecao disparada nos 2 grupos. Confira: az group list -o table"

# ---- GitOps com Argo CD na Azure ------------------------------------------ #
set-acr: ## Grava o nome real do ACR nos overlays (necessario para GitOps): make set-acr ACR=<acr>
	@ACR="$(ACR)" bash scripts/set-acr.sh

# --- multi-DC: UM Argo CD no dc1 governando os DOIS clusters (hub-and-spoke) --
mdc-argo-install: ## [multi-DC] Instala o Argo CD no cluster do dc1 (o hub)
	@CTX=$(MDC_CTX1) bash scripts/argocd-install.sh

mdc-argo-register-dc2: ## [multi-DC] Registra o cluster do dc2 como destino remoto
	@HUB_CTX=$(MDC_CTX1) REMOTE_CTX=$(MDC_CTX2) REMOTE_NAME=dc2 \
	  bash scripts/argocd-register-cluster.sh

mdc-argo-apps: ## [multi-DC] Registra as 2 Applications: make mdc-argo-apps REPO=<git>
	@HUB_CTX=$(MDC_CTX1) REMOTE_CTX=$(MDC_CTX2) REPO="$(REPO)" \
	  BRANCH="$(or $(BRANCH),main)" bash scripts/argocd-app-multidc.sh

mdc-argo-bootstrap: mdc-argo-install mdc-argo-register-dc2 mdc-argo-apps ## [multi-DC] GitOps de ponta a ponta

MDC_ARGO_DNS ?= argocd-tp01-$(shell whoami | tr -cd '[:alnum:]' | tr 'A-Z' 'a-z')

mdc-argo-expose: ## [multi-DC] Publica a UI do Argo num dominio da Azure (default: so o seu IP)
	@CTX=$(MDC_CTX1) DNS_LABEL=$(MDC_ARGO_DNS) SOURCE_CIDR="$(SOURCE_CIDR)" \
	  bash scripts/argocd-expose.sh

mdc-argo-unexpose: ## [multi-DC] Remove a exposicao publica da UI do Argo
	kubectl --context $(MDC_CTX1) -n argocd delete svc argocd-server-public --ignore-not-found

mdc-argo-ui: ## [multi-DC] Port-forward da UI do Argo CD (hub no dc1)
	@echo "UI: https://localhost:8080  (admin / make mdc-argo-password)"
	kubectl --context $(MDC_CTX1) -n argocd port-forward svc/argocd-server 8080:443

mdc-argo-password: ## [multi-DC] Senha inicial do usuario admin
	@kubectl --context $(MDC_CTX1) -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d; echo

mdc-argo-status: ## [multi-DC] Estado das Applications e dos clusters registrados
	kubectl --context $(MDC_CTX1) -n argocd get applications \
	  -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,SAUDE:.status.health.status,DESTINO:.spec.destination.server'
	@echo
	kubectl --context $(MDC_CTX1) -n argocd get secret \
	  -l argocd.argoproj.io/secret-type=cluster \
	  -o custom-columns='CLUSTER:.metadata.name,NOME:.data.name' 2>/dev/null || true

mdc-argo-sync: ## [multi-DC] Forca sync imediato das 2 Applications
	@for app in tp01-cassandra-dc1 tp01-cassandra-dc2; do \
	  kubectl --context $(MDC_CTX1) -n argocd patch application $$app --type merge \
	    -p '{"operation":{"initiatedBy":{"username":"make"},"sync":{"revision":"HEAD"}}}'; \
	done

mdc-argo-down: ## [multi-DC] Remove Applications, registro do dc2 e o Argo CD
	-kubectl --context $(MDC_CTX1) -n argocd delete application tp01-cassandra-dc1 tp01-cassandra-dc2 --ignore-not-found
	-kubectl --context $(MDC_CTX1) -n argocd delete secret cluster-dc2 --ignore-not-found
	-kubectl --context $(MDC_CTX2) delete clusterrolebinding argocd-manager-binding --ignore-not-found
	-kubectl --context $(MDC_CTX2) -n kube-system delete sa argocd-manager --ignore-not-found
	-kubectl --context $(MDC_CTX2) -n kube-system delete secret argocd-manager-token --ignore-not-found
	kubectl --context $(MDC_CTX1) delete namespace argocd --ignore-not-found

down: ## Destroi o cluster kind (apaga tudo)
	kind delete cluster --name $(CLUSTER)

clean: down ## Alias de down
