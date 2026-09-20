#!/usr/bin/env bash
# Cria os dois clusters AKS, um em cada região, dentro das VNets já criadas.
#
# Decisões que importam:
#   --zones 1 2      2 zonas, 3 nós => 2 VMs na zona 1, 1 VM na zona 2. Isso
#                    casa com a topologia do Cassandra: rack1 (2 nós) na zona 1
#                    e rack2 (1 nó) na zona 2. Rack == domínio de falha real.
#   --network-plugin azure --network-plugin-mode overlay
#                    Pod IP fica interno ao cluster (não consome a subnet). Não
#                    precisa ser roteável entre regiões porque o gossip entre
#                    DCs passa pelos IPs fixos dos internal LBs, não pelos pods.
#   --vnet-subnet-id Os NÓS ficam na snet-nodes da VNet peered.
set -euo pipefail

RG1="${RG1:?}"; LOC1="${LOC1:?}"; AKS1="${AKS1:?}"; VNET1="${VNET1:-vnet-dc1}"
RG2="${RG2:?}"; LOC2="${LOC2:?}"; AKS2="${AKS2:?}"; VNET2="${VNET2:-vnet-dc2}"
ACR="${ACR:?}"; ACR_RG="${ACR_RG:-$RG1}"
VM="${VM:-Standard_B2s_v2}"; NODES="${NODES:-3}"
# Zonas por regiao. NAO sao iguais em toda regiao: alem de a regiao precisar ter
# zonas, a SUA subscription pode estar barrada numa delas
# (restricao "NotAvailableForSubscription"). Confira antes com:
#   az vm list-skus -l <regiao> --size <sku> --query "[].restrictions"
ZONES1="${ZONES1:-1 2}"   # chilecentral
ZONES2="${ZONES2:-2 3}"   # mexicocentral: zona 1 barrada para esta subscription

ACR_ID="$(az acr show -g "$ACR_RG" -n "$ACR" --query id -o tsv)"

mk_cluster() {
  local rg="$1" loc="$2" aks="$3" vnet="$4" zones="$5"
  local subnet_id vnet_id principal
  subnet_id="$(az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n snet-nodes --query id -o tsv)"
  vnet_id="$(az network vnet show -g "$rg" -n "$vnet" --query id -o tsv)"

  # Idempotente: re-rodar o bootstrap depois de uma falha parcial nao pode
  # explodir no cluster que ja subiu.
  if az aks show -g "$rg" -n "$aks" --query name -o tsv >/dev/null 2>&1; then
    echo ">> AKS $aks ja existe em $loc — pulando criacao"
    # Re-anexa o ACR: se o registro foi recriado, a permissao AcrPull antiga
    # aponta para um recurso que nao existe mais e o pull falharia.
    echo "   re-anexando o ACR"
    az aks update -g "$rg" -n "$aks" --attach-acr "$ACR_ID" -o none 2>/dev/null \
      || echo "   (ja estava anexado)"
  else
  echo ">> AKS $aks em $loc, zonas [$zones] (leva ~5 min)"
  az aks create -g "$rg" -n "$aks" -l "$loc" \
    --node-count "$NODES" --node-vm-size "$VM" --zones $zones \
    --network-plugin azure --network-plugin-mode overlay \
    --pod-cidr 10.244.0.0/16 --service-cidr 10.0.0.0/16 --dns-service-ip 10.0.0.10 \
    --vnet-subnet-id "$subnet_id" \
    --attach-acr "$ACR_ID" \
    --enable-managed-identity --generate-ssh-keys --tier free -o none
  fi

  # O AKS precisa poder criar frontends de internal LB na subnet snet-lb, que
  # não é a subnet dele. Sem isso os Services de LB ficam <pending> para sempre.
  principal="$(az aks show -g "$rg" -n "$aks" --query identity.principalId -o tsv)"
  echo ">> Concedendo Network Contributor em $vnet para a identidade do $aks"
  az role assignment create --assignee-object-id "$principal" \
    --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" --scope "$vnet_id" -o none 2>/dev/null \
    || echo "   (a atribuicao ja existia)"
}

mk_cluster "$RG1" "$LOC1" "$AKS1" "$VNET1" "$ZONES1"
mk_cluster "$RG2" "$LOC2" "$AKS2" "$VNET2" "$ZONES2"

echo ">> Baixando kubeconfig dos dois clusters"
az aks get-credentials -g "$RG1" -n "$AKS1" --overwrite-existing
az aks get-credentials -g "$RG2" -n "$AKS2" --overwrite-existing

echo ">> Zonas de cada nó (confira 2 na zona -1 e 1 na zona -2 por cluster):"
for ctx in "$AKS1" "$AKS2"; do
  echo "--- $ctx ---"
  kubectl --context "$ctx" get nodes \
    -o custom-columns='NO:.metadata.name,ZONA:.metadata.labels.topology\.kubernetes\.io/zone'
done
