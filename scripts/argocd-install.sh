#!/usr/bin/env bash
# Instala o Argo CD num cluster (kind ou AKS) e espera ele ficar pronto.
# Idempotente: rodar de novo apenas reaplica/atualiza.
set -euo pipefail

# CTX: contexto kubectl alvo. Vazio = contexto atual (comportamento no kind).
# No Azure aponte para o cluster AKS: CTX=aks-tp01 ou CTX=aks-tp01-dc1.
CTX="${CTX:-}"
kubectl() { command kubectl ${CTX:+--context "$CTX"} "$@"; }

ARGO_NS="${ARGO_NS:-argocd}"
# Versão do Argo CD. "stable" pega o último release estável; fixe uma tag
# (ex.: v2.13.2) se quiser reprodutibilidade total na apresentação.
ARGO_VERSION="${ARGO_VERSION:-stable}"
INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

echo "== Namespace ${ARGO_NS} =="
kubectl apply -f "$(dirname "$0")/../k8s/argocd/00-namespace.yaml"

echo
echo "== Instalando Argo CD (${ARGO_VERSION}) =="
# --server-side: os CRDs do Argo (ex.: applicationsets) são grandes demais para o
# annotation 'last-applied-configuration' do apply client-side (limite de 256 KB).
# O server-side apply não usa esse annotation. --force-conflicts assume a posse
# de campos caso uma instalação anterior client-side tenha deixado resíduo.
kubectl apply -n "$ARGO_NS" --server-side --force-conflicts -f "$INSTALL_URL"

echo
echo "== Esperando os componentes do Argo CD ficarem Ready =="
# O server é o que expõe a UI/API; esperar ele basta pro dia a dia.
kubectl -n "$ARGO_NS" rollout status deploy/argocd-server --timeout=300s
kubectl -n "$ARGO_NS" rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n "$ARGO_NS" rollout status statefulset/argocd-application-controller --timeout=300s 2>/dev/null || true

echo
echo "Argo CD instalado. Próximos passos:"
echo "  make argo-app REPO=https://github.com/<voce>/<repo> BRANCH=main APP_PATH=tp-01/k8s"
echo "  make argo-ui        # abre a UI em https://localhost:8080"
echo "  make argo-password  # senha inicial do usuário 'admin'"
