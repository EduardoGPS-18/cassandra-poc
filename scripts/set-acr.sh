#!/usr/bin/env bash
# Troca o REGISTRY_PLACEHOLDER dos overlays pelo nome real do seu ACR.
#
# Por que existe: no fluxo manual, os `make mdc-deploy-*` fazem
# essa substituição em memória, na hora de aplicar. No fluxo GitOps não dá: o
# Argo CD lê os arquivos DO GIT, então o valor real precisa estar commitado.
set -euo pipefail
ACR="${ACR:?Uso: make set-acr ACR=<nome-do-acr>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FILES=(
  "$DIR/azure-multidc/base/kustomization.yaml"
)

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  if grep -q 'REGISTRY_PLACEHOLDER' "$f"; then
    sed -i.bak "s|REGISTRY_PLACEHOLDER|${ACR}.azurecr.io|g" "$f" && rm -f "$f.bak"
    echo ">> $f  ->  ${ACR}.azurecr.io"
  else
    echo ">> $f  (já ajustado, nada a fazer)"
  fi
done

echo
echo "Agora commite para o Argo enxergar:"
echo "  git add azure-multidc && git commit -m 'chore: aponta overlays para o ACR ${ACR}' && git push"
