#!/usr/bin/env bash
# Registra os resource providers que esta infra usa.
#
# Por que isso existe: uma subscription NOVA não vem com nenhum provider
# habilitado. Antes de criar o primeiro recurso de um tipo, a subscription
# precisa declarar "quero usar este serviço" — é o `az provider register`.
# Sem isso a Azure responde MissingSubscriptionRegistration.
#
# É idempotente, gratuito e leva alguns minutos na primeira vez. Registrar
# dispara em paralelo; depois esperamos todos ficarem Registered.
set -euo pipefail

PROVIDERS=(
  Microsoft.ContainerRegistry     # ACR — o registro de imagens
  Microsoft.ContainerService      # AKS — os clusters Kubernetes
  Microsoft.Network               # VNets, subnets, peering, Load Balancers
  Microsoft.Compute               # as VMs dos nós e os discos gerenciados
  Microsoft.Storage               # contas de storage que o AKS usa internamente
  Microsoft.Insights              # métricas da plataforma
  Microsoft.OperationalInsights   # exigido pelo AKS mesmo sem monitoring ligado
)

echo "== Disparando o registro (não bloqueia) =="
for ns in "${PROVIDERS[@]}"; do
  estado="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
  if [ "$estado" = "Registered" ]; then
    echo "   $ns já registrado"
  else
    echo "   $ns -> registrando"
    az provider register -n "$ns" >/dev/null
  fi
done

echo
echo "== Esperando todos ficarem Registered (alguns minutos na 1ª vez) =="
DEADLINE=$(( $(date +%s) + 900 ))
for ns in "${PROVIDERS[@]}"; do
  printf "   %-32s" "$ns"
  while :; do
    estado="$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo Unknown)"
    [ "$estado" = "Registered" ] && { echo " Registered"; break; }
    [ "$(date +%s)" -ge "$DEADLINE" ] && { echo " TIMEOUT (estado: $estado)"; exit 1; }
    printf "."
    sleep 10
  done
done

echo
echo ">> Tudo pronto. Pode seguir com: make mdc-bootstrap"
