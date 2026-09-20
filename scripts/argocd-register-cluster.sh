#!/usr/bin/env bash
# Registra um cluster REMOTO no Argo CD — o passo que falta para um único Argo
# (no dc1) governar os dois clusters AKS.
#
# Como o Argo CD enxerga outros clusters: ele procura Secrets no seu namespace
# com a label `argocd.argoproj.io/secret-type: cluster`. Cada Secret carrega a
# URL da API, o CA e um bearer token. O `argocd cluster add` da CLI só faz isso
# — aqui montamos o Secret na mão, para não precisar instalar nem logar na CLI.
#
# Uso:
#   HUB_CTX=aks-tp01-dc1 REMOTE_CTX=aks-tp01-dc2 REMOTE_NAME=dc2 \
#     bash scripts/argocd-register-cluster.sh
set -euo pipefail

ARGO_NS="${ARGO_NS:-argocd}"
HUB_CTX="${HUB_CTX:?contexto do cluster onde o Argo CD roda}"
REMOTE_CTX="${REMOTE_CTX:?contexto do cluster a registrar}"
REMOTE_NAME="${REMOTE_NAME:-$REMOTE_CTX}"
SA_NS="${SA_NS:-kube-system}"
SA="${SA:-argocd-manager}"
SA_SECRET="${SA:-argocd-manager}-token"

echo "== 1. ServiceAccount '$SA' no cluster remoto ($REMOTE_CTX) =="
# cluster-admin porque o Argo precisa criar/apagar qualquer recurso que apareça
# no Git. Num cenário real você restringiria isso a um Role por namespace.
kubectl --context "$REMOTE_CTX" -n "$SA_NS" create serviceaccount "$SA" \
  --dry-run=client -o yaml | kubectl --context "$REMOTE_CTX" apply -f -

kubectl --context "$REMOTE_CTX" create clusterrolebinding "${SA}-binding" \
  --clusterrole=cluster-admin --serviceaccount="${SA_NS}:${SA}" \
  --dry-run=client -o yaml | kubectl --context "$REMOTE_CTX" apply -f -

echo
echo "== 2. Token de longa duração para essa conta =="
# A partir do k8s 1.24 uma ServiceAccount não ganha mais Secret de token
# automaticamente — é preciso criar o Secret explicitamente e deixar o
# controlador preenchê-lo.
kubectl --context "$REMOTE_CTX" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_SECRET}
  namespace: ${SA_NS}
  annotations:
    kubernetes.io/service-account.name: ${SA}
type: kubernetes.io/service-account-token
YAML

echo -n "   aguardando o token ser preenchido"
for _ in $(seq 1 30); do
  TOKEN="$(kubectl --context "$REMOTE_CTX" -n "$SA_NS" get secret "$SA_SECRET" \
    -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [ -n "$TOKEN" ] && break
  echo -n "."; sleep 2
done
echo
[ -n "${TOKEN:-}" ] || { echo "!! token não foi gerado em 60s"; exit 1; }
TOKEN="$(echo "$TOKEN" | base64 -d)"
CA="$(kubectl --context "$REMOTE_CTX" -n "$SA_NS" get secret "$SA_SECRET" \
  -o jsonpath='{.data.ca\.crt}')"   # já vem em base64, que é o formato do caData

echo
echo "== 3. Descobrindo a URL da API do cluster remoto =="
REMOTE_CLUSTER="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${REMOTE_CTX}')].context.cluster}")"
SERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${REMOTE_CLUSTER}')].cluster.server}")"
[ -n "$SERVER" ] || { echo "!! não achei a URL da API para o contexto $REMOTE_CTX"; exit 1; }
echo "   $SERVER"

echo
echo "== 4. Secret de cluster no Argo CD ($HUB_CTX) =="
kubectl --context "$HUB_CTX" -n "$ARGO_NS" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${REMOTE_NAME}
  namespace: ${ARGO_NS}
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${REMOTE_NAME}
  server: ${SERVER}
  config: |
    {
      "bearerToken": "${TOKEN}",
      "tlsClientConfig": { "caData": "${CA}" }
    }
YAML

echo
echo ">> Cluster '${REMOTE_NAME}' registrado. Use nas Applications:"
echo "     destination.server: ${SERVER}"
echo ">> Confira na UI em Settings > Clusters, ou:"
echo "     kubectl --context ${HUB_CTX} -n ${ARGO_NS} get secret -l argocd.argoproj.io/secret-type=cluster"
