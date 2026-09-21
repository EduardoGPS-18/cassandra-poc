#!/usr/bin/env bash
# Expoe a UI do Argo CD num dominio publico da Azure, sem port-forward.
#
# Cria um Service SEPARADO (argocd-server-public) em vez de alterar o
# argocd-server original — assim uma reinstalacao do Argo nao desfaz isto, e
# remover a exposicao e so apagar este Service.
#
# O dominio vem de graca: a anotacao azure-dns-label-name registra
#   <rotulo>.<regiao>.cloudapp.azure.com
# no DNS publico da Azure, apontando para o IP do Load Balancer.
#
# SEGURANCA: o Argo CD tem cluster-admin nos DOIS clusters. Por isso o default
# e liberar apenas o SEU IP (SOURCE_CIDR). Para abrir de verdade, passe
# SOURCE_CIDR=0.0.0.0/0 — e so faca isso depois de trocar a senha do admin.
set -euo pipefail

ARGO_NS="${ARGO_NS:-argocd}"
CTX="${CTX:?contexto kubectl do cluster onde o Argo roda}"
DNS_LABEL="${DNS_LABEL:?rotulo DNS, unico na regiao (ex.: argocd-tp01-nieg)}"
SOURCE_CIDR="${SOURCE_CIDR:-}"

if [ -z "$SOURCE_CIDR" ]; then
  MEU_IP="$(curl -s -m 10 https://api.ipify.org || true)"
  [ -n "$MEU_IP" ] || { echo "!! nao consegui descobrir seu IP; passe SOURCE_CIDR=x.x.x.x/32"; exit 1; }
  SOURCE_CIDR="${MEU_IP}/32"
  echo ">> Restringindo acesso ao seu IP atual: $SOURCE_CIDR"
  echo "   (para abrir para qualquer origem: SOURCE_CIDR=0.0.0.0/0)"
fi

echo ">> Criando Service publico no namespace $ARGO_NS"
kubectl --context "$CTX" apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-public
  namespace: ${ARGO_NS}
  labels:
    app.kubernetes.io/name: argocd-server-public
  annotations:
    service.beta.kubernetes.io/azure-dns-label-name: "${DNS_LABEL}"
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
    - ${SOURCE_CIDR}
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: https
      port: 443
      targetPort: 8080
YAML

echo
echo -n ">> Esperando o IP publico ser atribuido"
for _ in $(seq 1 60); do
  IP="$(kubectl --context "$CTX" -n "$ARGO_NS" get svc argocd-server-public \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$IP" ] && break
  printf "."; sleep 5
done
echo
[ -n "${IP:-}" ] || { echo "!! o Service ficou <pending>. Cheque cota de IP publico na subscription."; exit 1; }

REGIAO="$(kubectl --context "$CTX" get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}')"
echo
echo "   IP publico : $IP"
echo "   Dominio    : https://${DNS_LABEL}.${REGIAO}.cloudapp.azure.com"
echo "   Origem     : $SOURCE_CIDR"
echo
echo ">> O certificado e autoassinado — o navegador vai avisar. Prossiga."
echo ">> TROQUE A SENHA DO ADMIN antes de abrir para 0.0.0.0/0:"
echo "   argocd login <dominio> --username admin --password \$(make mdc-argo-password) --insecure"
echo "   argocd account update-password"
