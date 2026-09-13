#!/usr/bin/env bash
# Verifica se o ambiente está pronto ANTES de tentar subir o cluster.
set -euo pipefail

ok=0
check() {
  if command -v "$1" >/dev/null 2>&1; then
    printf "  \033[32m✓\033[0m %-10s %s\n" "$1" "$($1 version 2>/dev/null | head -1 || true)"
  else
    printf "  \033[31m✗\033[0m %-10s NAO INSTALADO\n" "$1"
    ok=1
  fi
}

echo "== Ferramentas =="
check docker
check kind
check kubectl

echo "== Docker daemon =="
if docker info >/dev/null 2>&1; then
  printf "  \033[32m✓\033[0m docker daemon acessível\n"
else
  printf "  \033[31m✗\033[0m docker daemon NÃO acessível — abra o Docker Desktop\n"
  ok=1
fi

if [ "$ok" -ne 0 ]; then
  echo
  echo "Faltam pré-requisitos. Rode:  make tools   (instala kind) e abra o Docker Desktop."
  exit 1
fi
echo
echo "Ambiente OK."
