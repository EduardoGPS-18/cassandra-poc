#!/usr/bin/env bash
# Rede das duas regiões: 1 VNet por região + peering global entre elas.
#
# Plano de endereçamento (não pode haver sobreposição entre as duas VNets,
# senão o peering é recusado):
#
#   dc1  vnet-dc1  10.10.0.0/16   snet-nodes 10.10.0.0/20   snet-lb 10.10.32.0/24
#   dc2  vnet-dc2  10.20.0.0/16   snet-nodes 10.20.0.0/20   snet-lb 10.20.32.0/24
#
# snet-lb é uma subnet dedicada só para os IPs fixos dos internal LBs do
# Cassandra (um por nó). São esses IPs que atravessam o peering carregando o
# gossip entre os DCs.
set -euo pipefail

RG1="${RG1:?}"; LOC1="${LOC1:?}"; VNET1="${VNET1:-vnet-dc1}"; CIDR1="${CIDR1:-10.10.0.0/16}"
RG2="${RG2:?}"; LOC2="${LOC2:?}"; VNET2="${VNET2:-vnet-dc2}"; CIDR2="${CIDR2:-10.20.0.0/16}"

# Idempotente de proposito. `az network vnet create` numa VNet que ja existe
# RECONCILIA a lista de subnets: como o comando declara so a snet-nodes, a Azure
# tenta remover a snet-lb — e falha com InUseSubnetCannotBeDeleted assim que os
# internal LBs do Cassandra existirem. Por isso criamos cada peca so se faltar.
mk_vnet() {
  local rg="$1" loc="$2" vnet="$3" cidr="$4" nodes="$5" lb="$6"
  if az network vnet show -g "$rg" -n "$vnet" -o none 2>/dev/null; then
    echo ">> VNet $vnet ja existe em $loc — pulando"
  else
    echo ">> VNet $vnet ($cidr) em $loc"
    az network vnet create -g "$rg" -n "$vnet" -l "$loc" \
      --address-prefixes "$cidr" \
      --subnet-name snet-nodes --subnet-prefixes "$nodes" -o none
  fi

  if az network vnet subnet show -g "$rg" --vnet-name "$vnet" -n snet-lb -o none 2>/dev/null; then
    echo "   subnet snet-lb ja existe"
  else
    echo "   criando subnet snet-lb ($lb)"
    az network vnet subnet create -g "$rg" --vnet-name "$vnet" \
      -n snet-lb --address-prefixes "$lb" -o none
  fi
}

mk_vnet "$RG1" "$LOC1" "$VNET1" "$CIDR1" 10.10.0.0/20 10.10.32.0/24
mk_vnet "$RG2" "$LOC2" "$VNET2" "$CIDR2" 10.20.0.0/20 10.20.32.0/24

ID1="$(az network vnet show -g "$RG1" -n "$VNET1" --query id -o tsv)"
ID2="$(az network vnet show -g "$RG2" -n "$VNET2" --query id -o tsv)"

# Peering é DIRECIONAL: precisa dos dois lados para o tráfego fluir.
echo ">> Peering $VNET1 <-> $VNET2 (global: regiões diferentes)"
mk_peering() {
  local rg="$1" nome="$2" vnet="$3" remoto="$4"
  if az network vnet peering show -g "$rg" --vnet-name "$vnet" -n "$nome" -o none 2>/dev/null; then
    echo "   $nome ja existe"
  else
    az network vnet peering create -g "$rg" -n "$nome" \
      --vnet-name "$vnet" --remote-vnet "$remoto" --allow-vnet-access -o none
  fi
}
mk_peering "$RG1" "${VNET1}-to-${VNET2}" "$VNET1" "$ID2"
mk_peering "$RG2" "${VNET2}-to-${VNET1}" "$VNET2" "$ID1"

echo ">> Estado do peering (esperado: Connected nos dois):"
az network vnet peering list -g "$RG1" --vnet-name "$VNET1" \
  --query "[].{nome:name, estado:peeringState}" -o table
az network vnet peering list -g "$RG2" --vnet-name "$VNET2" \
  --query "[].{nome:name, estado:peeringState}" -o table
