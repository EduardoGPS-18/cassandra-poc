#!/usr/bin/env bash
# Desliga / religa os dois clusters AKS sem destruir nada.
#
#   stop   -> desaloca as VMs dos nós. Para de pagar computação, que é o grosso
#             da conta. Sobrevivem: discos (com os dados do Cassandra), IPs
#             fixos dos internal LBs, Services, manifestos e o ACR.
#   start  -> religa e espera o anel voltar a ficar completo.
#
# Por que o Cassandra sobrevive a isso: as VMs voltam com IPs de pod novos, mas
# o `broadcast_address` de cada nó é o IP fixo do internal LB — que não muda.
# Os nós reaparecem no anel com a MESMA identidade e reencontram os dados nos
# PVCs. É exatamente o problema que o desenho de endereçamento resolveu.
#
# Uso:  bash scripts/azure-multidc-power.sh stop|start
set -euo pipefail

ACAO="${1:-}"
RG1="${RG1:?}"; AKS1="${AKS1:?}"; CTX1="${CTX1:-$AKS1}"
RG2="${RG2:?}"; AKS2="${AKS2:?}"; CTX2="${CTX2:-$AKS2}"
NS="${NS:-sd}"

# ATENÇÃO ao campo certo: o powerState vira Stopped/Running assim que as VMs
# caem ou sobem, mas a operação no plano de controle continua rodando. Quem diz
# que ela ACABOU é o provisioningState voltando para "Succeeded". Esperar só o
# powerState faz o próximo comando falhar com OperationNotAllowed.
estado() {
  # `-o tsv` numa LISTA devolve um valor POR LINHA (não separados por tab), e o
  # `read -r p s` só pegaria o primeiro. O tr achata tudo numa linha só.
  az aks show -g "$1" -n "$2" --query "[powerState.code, provisioningState]" -o tsv 2>/dev/null \
    | tr '\n' ' ' || echo "? ?"
}

aguardar() {   # rg aks powerState-esperado
  local rg="$1" aks="$2" alvo="$3" p s fim
  fim=$(( $(date +%s) + 1800 ))
  printf "   %-16s" "$aks"
  while :; do
    read -r p s <<<"$(estado "$rg" "$aks")"
    if [ "$p" = "$alvo" ] && [ "$s" = "Succeeded" ]; then echo " $p"; return 0; fi
    if [ "$(date +%s)" -ge "$fim" ]; then
      echo " TIMEOUT (power=$p provisioning=$s)"; return 1
    fi
    printf "."
    sleep 15
  done
}

case "$ACAO" in
  stop)
    # ------------------------------------------------------------------------
    # DRAIN ANTES DE DESLIGAR — não é opcional.
    #
    # `az aks stop` DESALOCA as VMs; ele não faz eviction graciosa dos pods, e o
    # preStop do StatefulSet não chega a rodar. O Cassandra morre no meio de uma
    # escrita e o último segmento do commit log fica truncado. Na volta ele se
    # recusa a subir:
    #     CommitLogReadException: Mutation checksum failure ...
    #     -> CrashLoopBackOff, exit code 100
    #
    # `nodetool drain` resolve na raiz: para de aceitar escritas e descarrega as
    # memtables em SSTables. Depois dele o commit log não tem nada pendente, e o
    # replay na volta é um no-op.
    # ------------------------------------------------------------------------
    echo "== 1. Parando as escritas (gerador de carga) =="
    for ctx in "$CTX1" "$CTX2"; do
      kubectl --context "$ctx" -n "$NS" scale deploy/loadgen --replicas=0 2>/dev/null \
        && echo "   $ctx: loadgen parado" || echo "   $ctx: sem loadgen ativo"
    done

    echo
    echo "== 2. nodetool drain em cada nó (descarrega memtables) =="
    for ctx in "$CTX1" "$CTX2"; do
      for pod in $(kubectl --context "$ctx" -n "$NS" get pods -l app=cassandra \
                     -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        printf "   %-16s %-20s" "$ctx" "$pod"
        if kubectl --context "$ctx" -n "$NS" exec "$pod" -- nodetool drain >/dev/null 2>&1; then
          echo "drenado"
        else
          echo "FALHOU (nó já fora? siga, mas confira na volta)"
        fi
      done
    done

    echo
    echo "== 3. Desligando os dois clusters =="
    az aks stop -g "$RG1" -n "$AKS1" --no-wait
    az aks stop -g "$RG2" -n "$AKS2" --no-wait
    # Desligar os dois JUNTOS importa: se um ficasse de pé enquanto o outro cai,
    # ele marcaria o DC ausente como DOWN e acumularia hints para entregar
    # depois — trabalho inútil, e uma tempestade de hints no retorno.
    aguardar "$RG1" "$AKS1" Stopped
    aguardar "$RG2" "$AKS2" Stopped
    echo
    echo ">> Computação parada. Continuam cobrando (centavos/dia): discos, IPs e ACR."
    echo ">> Os nós foram drenados: na volta o commit log sobe limpo."
    echo ">> Para voltar:  make mdc-start   — reserve ~20 min antes da apresentação."
    ;;

  start)
    echo "== Conferindo se não há operação em andamento =="
    # az aks start recusa ("OperationNotAllowed") se um stop anterior ainda
    # estiver finalizando. Esperamos o provisioningState assentar primeiro.
    for par in "$RG1 $AKS1" "$RG2 $AKS2"; do
      set -- $par
      read -r _ st <<<"$(estado "$1" "$2")"
      if [ "$st" != "Succeeded" ]; then
        printf "   %-16s (operação %s em curso, aguardando)" "$2" "$st"
        until read -r _ st <<<"$(estado "$1" "$2")"; [ "$st" = "Succeeded" ]; do
          printf "."; sleep 15
        done
        echo " ok"
      fi
    done

    echo
    echo "== Religando os dois clusters =="
    az aks start -g "$RG1" -n "$AKS1" --no-wait
    az aks start -g "$RG2" -n "$AKS2" --no-wait
    aguardar "$RG1" "$AKS1" Running
    aguardar "$RG2" "$AKS2" Running

    echo
    echo "== Esperando os nós do Cassandra (boot ordenado, um por vez) =="
    for ctx in "$CTX1" "$CTX2"; do
      echo "   --- $ctx ---"
      for sts in cassandra-rack1 cassandra-rack2; do
        kubectl --context "$ctx" -n "$NS" rollout status "sts/$sts" --timeout=900s
      done
    done

    echo
    echo "== Religando o gerador de carga do dc1 =="
    kubectl --context "$CTX1" -n "$NS" scale deploy/loadgen --replicas=1 >/dev/null 2>&1 \
      && echo "   loadgen de volta" || echo "   (nenhum loadgen para religar)"

    echo
    echo "== Anel (esperado: 6 linhas UN, 3 por datacenter) =="
    kubectl --context "$CTX1" exec -n "$NS" cassandra-rack1-0 -- nodetool status
    ;;

  *)
    echo "Uso: $0 stop|start" >&2
    exit 1
    ;;
esac
