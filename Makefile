# TP01 - Apache Cassandra em Kubernetes (kind) — atalhos do ciclo de vida.
# Uso: `make help`
NS      ?= sd
CLUSTER ?= sd-cassandra
KUBECONFIG_CTX = kind-$(CLUSTER)

.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help tools preflight up deploy wait keyspace status cqlsh pf kill-demo test scale down clean bootstrap \
        app-build app-load app-deploy app-up app-logs app-restart app-down \
        argo-install argo-app argo-ui argo-password argo-sync argo-down

help: ## Mostra esta ajuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

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
	@COUNT=$(or $(N),1) MODE=$(or $(MODE),abrupt) bash scripts/kill-node-demo.sh

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

down: ## Destroi o cluster kind (apaga tudo)
	kind delete cluster --name $(CLUSTER)

clean: down ## Alias de down
