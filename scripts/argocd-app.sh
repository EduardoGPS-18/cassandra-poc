#!/usr/bin/env bash
# Registra (ou atualiza) a Application do TP no Argo CD, renderizando o template
# k8s/argocd/application.yaml com o SEU repositório.
#
# Uso:
#   REPO=https://github.com/<voce>/SD [BRANCH=main] [APP_PATH=tp-01/k8s] bash scripts/argocd-app.sh
set -euo pipefail

ARGO_NS="${ARGO_NS:-argocd}"
export REPO_URL="${REPO:?Defina REPO=https://github.com/<voce>/<repo> (o Git que o Argo vai seguir)}"
export BRANCH="${BRANCH:-main}"
export APP_PATH="${APP_PATH:-k8s}"

TEMPLATE="$(dirname "$0")/../k8s/argocd/application.yaml"

echo "== Application do Argo CD =="
echo "   repoURL : ${REPO_URL}"
echo "   branch  : ${BRANCH}"
echo "   path    : ${APP_PATH}"
echo

# Renderiza o template. Preferimos envsubst (gettext); se não houver, caímos
# num sed que troca só os 3 placeholders — sem tocar em outros '$' do YAML.
render() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${REPO_URL} ${BRANCH} ${APP_PATH}' < "$TEMPLATE"
  else
    sed -e "s|\${REPO_URL}|${REPO_URL}|g" \
        -e "s|\${BRANCH}|${BRANCH}|g" \
        -e "s|\${APP_PATH}|${APP_PATH}|g" "$TEMPLATE"
  fi
}

render | kubectl apply -n "$ARGO_NS" -f -

echo
echo "Application aplicada. Acompanhe a sincronização:"
echo "  kubectl -n ${ARGO_NS} get application tp01-cassandra -w"
echo "  make status   # quando sincronizar, os 5 nós do Cassandra sobem sozinhos"
