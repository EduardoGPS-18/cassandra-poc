#!/usr/bin/env bash
# Registra as DUAS Applications (dc1 e dc2) num único Argo CD.
#
# Uso:
#   REPO=https://github.com/<voce>/cassandra-poc [BRANCH=main] \
#   HUB_CTX=aks-tp01-dc1 REMOTE_CTX=aks-tp01-dc2 \
#     bash scripts/argocd-app-multidc.sh
set -euo pipefail

ARGO_NS="${ARGO_NS:-argocd}"
HUB_CTX="${HUB_CTX:?contexto do cluster onde o Argo CD roda}"
REMOTE_CTX="${REMOTE_CTX:?contexto do cluster do dc2}"
export REPO_URL="${REPO:?Defina REPO=https://github.com/<voce>/<repo>}"
export BRANCH="${BRANCH:-main}"
export APP_PATH_DC1="${APP_PATH_DC1:-azure-multidc/dc1}"
export APP_PATH_DC2="${APP_PATH_DC2:-azure-multidc/dc2}"

TEMPLATE="$(dirname "$0")/../k8s/argocd/application-multidc.yaml"

# A URL da API do dc2 precisa ser EXATAMENTE a mesma que está no Secret de
# cluster, senão o Argo responde "cluster not found".
REMOTE_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${REMOTE_CTX}')].context.cluster}")"
export DC2_SERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${REMOTE_CLUSTER}')].cluster.server}")"
[ -n "$DC2_SERVER" ] || { echo "!! não achei a URL da API do contexto $REMOTE_CTX"; exit 1; }

# Falha cedo e com mensagem clara se o cluster remoto ainda não foi registrado.
if ! kubectl --context "$HUB_CTX" -n "$ARGO_NS" get secret \
      -l argocd.argoproj.io/secret-type=cluster -o name 2>/dev/null | grep -q .; then
  echo "!! nenhum cluster remoto registrado no Argo CD."
  echo "   Rode antes: make mdc-argo-register-dc2"
  exit 1
fi

# Aviso — e não erro — porque o placeholder só quebra o sync, não o registro.
if grep -rq 'REGISTRY_PLACEHOLDER' "$(dirname "$0")/../azure-multidc/base/kustomization.yaml"; then
  echo "!! ATENÇÃO: azure-multidc/base/kustomization.yaml ainda tem REGISTRY_PLACEHOLDER."
  echo "   O Argo lê do Git: rode 'make set-acr ACR=<seu-acr>', faça commit e push,"
  echo "   senão o Deployment do loadgen vai falhar ao puxar a imagem."
  echo
fi

echo "== Applications multi-DC =="
echo "   repoURL : ${REPO_URL} (${BRANCH})"
echo "   dc1     : ${APP_PATH_DC1} -> in-cluster"
echo "   dc2     : ${APP_PATH_DC2} -> ${DC2_SERVER}"
echo

render() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${REPO_URL} ${BRANCH} ${APP_PATH_DC1} ${APP_PATH_DC2} ${DC2_SERVER}' < "$TEMPLATE"
  else
    sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
        -e "s|\${BRANCH}|${BRANCH}|g" \
        -e "s|\${APP_PATH_DC1}|${APP_PATH_DC1}|g" \
        -e "s|\${APP_PATH_DC2}|${APP_PATH_DC2}|g" \
        -e "s|\${DC2_SERVER}|${DC2_SERVER}|g" "$TEMPLATE"
  fi
}

render | kubectl --context "$HUB_CTX" apply -n "$ARGO_NS" -f -

echo
echo "Acompanhe:"
echo "  kubectl --context ${HUB_CTX} -n ${ARGO_NS} get applications -w"
