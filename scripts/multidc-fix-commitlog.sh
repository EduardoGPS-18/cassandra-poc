#!/usr/bin/env bash
# Recupera um nó que não sobe por commit log corrompido.
#
# Sintoma:
#   CommitLogReadException: Mutation checksum failure ... in CommitLog-*.log
#   Exiting due to error while processing commit log during initialization
#   -> pod em CrashLoopBackOff, exit code 100
#
# Causa: o processo foi morto no meio de uma escrita (VM desalocada, OOM, kill -9)
# e o último segmento do commit log ficou truncado. O Cassandra se recusa a subir
# em vez de arriscar aplicar uma mutação pela metade.
#
# O que este script faz: apaga os commit logs DESTE nó. As escritas que ainda não
# tinham sido gravadas em SSTable se perdem LOCALMENTE — mas com RF=3 elas existem
# nas outras réplicas, e o `nodetool repair` do fim traz tudo de volta.
#
# Uso:  CTX=aks-tp01-dc1 POD=cassandra-rack1-1 bash scripts/multidc-fix-commitlog.sh
set -euo pipefail
NS="${NS:-sd}"
CTX="${CTX:?contexto kubectl do cluster}"
POD="${POD:?nome do pod, ex.: cassandra-rack1-1}"

STS="${POD%-*}"                 # cassandra-rack1-1 -> cassandra-rack1
ORD="${POD##*-}"                # -> 1
PVC="cassandra-data-${POD}"
K="kubectl --context $CTX -n $NS"

REPLICAS="$($K get sts "$STS" -o jsonpath='{.spec.replicas}')"
echo "== Alvo: $POD (sts $STS, réplicas atuais: $REPLICAS, PVC $PVC) =="
$K get pvc "$PVC" >/dev/null

# --------------------------------------------------------------------------
# ARGO CD: se houver Application com selfHeal governando este cluster, ela
# desfaz o `scale` em segundos e recria o pod — o script ficaria esperando para
# sempre um pod que o Argo insiste em manter de pé. Suspendemos o automatismo
# durante a manutenção e devolvemos no fim (inclusive se der erro no meio).
# --------------------------------------------------------------------------
ARGO_NS="${ARGO_NS:-argocd}"
APPS=""
if kubectl --context "$CTX" get ns "$ARGO_NS" >/dev/null 2>&1; then
  APPS="$(kubectl --context "$CTX" -n "$ARGO_NS" get applications \
          -o jsonpath='{range .items[?(@.spec.destination.server=="https://kubernetes.default.svc")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
fi

restaura_argo() {
  for app in $APPS; do
    kubectl --context "$CTX" -n "$ARGO_NS" patch application "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 \
      && echo "   sync automático restaurado em $app"
  done
}

if [ -n "$APPS" ]; then
  echo
  echo "== 0. Suspendendo o sync automático do Argo CD =="
  trap restaura_argo EXIT
  for app in $APPS; do
    kubectl --context "$CTX" -n "$ARGO_NS" patch application "$app" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
    echo "   $app suspenso"
  done
fi

echo
echo "== 1. Removendo o pod para liberar o disco =="
# StatefulSet remove sempre do maior ordinal para baixo; por isso só dá para
# soltar o disco de um pod encolhendo até o ordinal dele.
$K scale sts "$STS" --replicas="$ORD"
FIM=$(( $(date +%s) + 300 ))
until [ -z "$($K get pod "$POD" --ignore-not-found -o name)" ]; do
  if [ "$(date +%s)" -ge "$FIM" ]; then
    echo
    echo "!! O pod $POD continua de pé depois de 5 min — alguém o está recriando."
    echo "   Cheque se há outro controlador (Argo CD em outro namespace, um operador)"
    echo "   governando o StatefulSet $STS."
    exit 1
  fi
  printf "."; sleep 5
done
echo " pod removido (o PVC permanece)"

echo
echo "== 2. Limpando os commit logs =="
$K delete job fix-commitlog --ignore-not-found >/dev/null 2>&1 || true
cat <<YAML | $K apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: fix-commitlog
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: limpa
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - |
              echo "commit logs encontrados:"
              ls -la /data/commitlog/ 2>/dev/null || echo "  (nenhum)"
              rm -f /data/commitlog/*.log
              echo "removidos. Restante:"
              ls -la /data/commitlog/ 2>/dev/null || true
          volumeMounts:
            - { name: dados, mountPath: /data }
      volumes:
        - name: dados
          persistentVolumeClaim:
            claimName: ${PVC}
YAML
$K wait --for=condition=complete job/fix-commitlog --timeout=300s
$K logs job/fix-commitlog | sed 's/^/   /'
$K delete job fix-commitlog >/dev/null

echo
echo "== 3. Recolocando o nó no anel =="
$K scale sts "$STS" --replicas="$REPLICAS"
$K rollout status "sts/$STS" --timeout=900s

echo
echo "== 4. Anel =="
$K exec cassandra-rack1-0 -- nodetool status

echo
echo ">> O nó voltou, mas pode estar sem as escritas que estavam no commit log."
echo ">> Recupere-as das outras réplicas (leva alguns minutos):"
echo "   kubectl --context $CTX -n $NS exec $POD -- nodetool repair -pr"
