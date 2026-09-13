#!/usr/bin/env bash
# Teste AUTOMATIZADO de tolerância a falhas, de ponta a ponta.
#
# Fluxo: baseline -> derruba N pods -> observa a janela de falha ->
#        espera o anel recuperar -> imprime relatório com veredito.
#
# Parâmetros (via env / Makefile):
#   N=<n>        quantos pods derrubar               (default 1)
#   MODE=abrupt|graceful                             (default abrupt)
#   WINDOW=<s>   segundos observando durante a falha (default 30)
#
# Uso:  make test              (N=1, abrupto)
#       make test N=2          (2 pods)
#       make test N=3 MODE=graceful WINDOW=45
set -euo pipefail
NS="${NS:-sd}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="${N:-1}"
MODE="${MODE:-abrupt}"
WINDOW="${WINDOW:-30}"

hr() { printf '%s\n' "----------------------------------------------------------------"; }

# --- pré-condições ---------------------------------------------------------- #
if ! kubectl get deploy loadgen -n "$NS" >/dev/null 2>&1; then
  echo "!! A app de carga não está rodando. Suba antes com:  make app-up"
  exit 1
fi
kubectl -n "$NS" rollout status deploy/loadgen --timeout=120s >/dev/null

REPLICAS=$(kubectl get statefulset cassandra -n "$NS" -o jsonpath='{.spec.replicas}')
# Escolhe qualquer nó vivo para consultar o anel (cassandra-0 pode estar fora).
pick_live_node() {
  local p
  for p in $(kubectl get pods -n "$NS" -l app=cassandra \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="Running"{print $1}'); do
    if kubectl exec -n "$NS" "$p" -- nodetool status >/dev/null 2>&1; then echo "$p"; return 0; fi
  done
  return 0
}
un_count() {
  local h; h="$(pick_live_node)"
  [ -n "$h" ] || { echo 0; return 0; }
  kubectl exec -n "$NS" "$h" -- nodetool status 2>/dev/null | grep -c '^UN' || true
}
totals() { kubectl logs -n "$NS" -l app=loadgen --tail=60 2>/dev/null | grep -oE 'TOTAL ok=[0-9]+ err=[0-9]+' | tail -1; }
num() { echo "$1" | grep -oE "$2=[0-9]+" | grep -oE '[0-9]+'; }
# Percentis de latência do PERÍODO INTEIRO, calculados do jeito certo.
#
# NÃO se tira média de percentis: a média dos p95 de várias janelas NÃO é o p95
# do período (percentil não é aditivo). O certo é JUNTAR todas as amostras cruas
# e calcular o percentil UMA vez. O loadgen emite essas amostras em linhas
# "#LAT <ms> <ms> ...".  Saída: "p50=.. p95=.. p99=..  (amostras=N)".
#
# Fallback: se o log não tiver linhas "#LAT" (imagem antiga do loadgen, sem
# EMIT_LAT_SAMPLES), usa a PIOR janela de cada percentil — nunca a média — e
# rotula como aproximado.
lat_line() {
  local f="$1"
  if grep -q '^#LAT' "$f" 2>/dev/null; then
    awk '/^#LAT/{for(i=2;i<=NF;i++) print $(i)+0}' "$f" | sort -n | awk '
      # índice = nearest-rank, igual ao _pct() do loadgen: round(p/100*(N-1)), 1-based
      function q(p,   idx){ idx=int((p/100.0)*(NR-1)+0.5)+1; if(idx>NR)idx=NR; if(idx<1)idx=1; return v[idx] }
      { v[NR]=$1 }
      END{ if(NR==0){ printf "n/d"; exit }
           printf "p50=%.1f p95=%.1f p99=%.1f  (amostras=%d)", q(50), q(95), q(99), NR }'
  else
    awk '
      function upd(k){ for(i=1;i<NF;i++) if($i==k"="){ x=$(i+1)+0; if(x>m[k])m[k]=x; c[k]++ } }
      { upd("p50"); upd("p95"); upd("p99") }
      END{ if(c["p50"]+c["p95"]+c["p99"]==0){ printf "n/d (reimplante o loadgen: EMIT_LAT_SAMPLES=1)"; }
           else printf "p50=%.1f p95=%.1f p99=%.1f  (pior janela; aprox. — sem amostras cruas)", m["p50"], m["p95"], m["p99"] }' "$f"
  fi
}
# Agrega os motivos de erro a partir dos trechos "erros=Tipo:contagem,..." do log.
err_reasons() {
  local out
  out=$(grep -oE 'erros=[^ ]+' "$1" 2>/dev/null | sed 's/erros=//' | tr ',' '\n' \
        | awk -F: 'NF==2{a[$1]+=$2} END{for(k in a) printf "%s %d\n", k, a[k]}' \
        | sort -k2 -rn | awk '{printf "     %-20s %d\n", $1, $2}')
  [ -n "$out" ] && echo "$out" || echo "     (nenhum erro registrado)"
}

hr; echo " TESTE DE TOLERÂNCIA A FALHAS — N=$N pod(s), MODE=$MODE, WINDOW=${WINDOW}s"; hr

# --- baseline --------------------------------------------------------------- #
echo "[1/4] Baseline (cluster saudável) — medindo latência fora da falha..."
echo "  nós UN: $(un_count)/$REPLICAS"
BASECAP="$(mktemp)"
( kubectl logs -n "$NS" -l app=loadgen -f --since=1s >"$BASECAP" 2>/dev/null ) &
BPID=$!
sleep 10
kill "$BPID" >/dev/null 2>&1 || true
BEFORE="$(totals)"; OK0=$(num "$BEFORE" ok); ERR0=$(num "$BEFORE" err)
echo "  contadores da app: ok=$OK0 err=$ERR0"

# --- injeção da falha ------------------------------------------------------- #
echo; echo "[2/4] Injetando falha: derrubando $N pod(s)..."
COUNT="$N" MODE="$MODE" NS="$NS" bash "$DIR/scripts/kill-node-demo.sh" | sed 's/^/    /'

# --- janela de observação --------------------------------------------------- #
echo; echo "[3/4] Observando por ${WINDOW}s durante a falha (capturando latências)..."
LOGCAP="$(mktemp)"
# --since cobre o instante da injeção (o script de kill leva ~10s imprimindo o anel).
( kubectl logs -n "$NS" -l app=loadgen -f --since=12s >"$LOGCAP" 2>/dev/null ) &
LPID=$!
sleep "$WINDOW"
kill "$LPID" >/dev/null 2>&1 || true

# --- recuperação ------------------------------------------------------------ #
echo; echo "[4/4] Aguardando o anel recuperar ($REPLICAS nós UN)..."
t0=$(date +%s); RECOVERED="não (timeout)"
deadline=$(( t0 + 600 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  c=$(un_count)
  printf "\r  nós UN: %s/%s   (t+%ss)   " "$c" "$REPLICAS" "$(( $(date +%s) - t0 ))"
  if [ "$c" = "$REPLICAS" ]; then RECOVERED="$(( $(date +%s) - t0 ))s"; break; fi
  sleep 5
done
echo

AFTER="$(totals)"; OK1=$(num "$AFTER" ok); ERR1=$(num "$AFTER" err)
OK_D=$(( OK1 - OK0 )); ERR_D=$(( ERR1 - ERR0 ))
TOT_D=$(( OK_D + ERR_D )); RATE="100.000"
[ "$TOT_D" -gt 0 ] && RATE=$(awk "BEGIN{printf \"%.3f\", 100*$OK_D/$TOT_D}")

# --- relatório -------------------------------------------------------------- #
hr; echo " RELATÓRIO"; hr
printf "  pods derrubados........: %s (MODE=%s)\n" "$N" "$MODE"
printf "  operações no período...: %s (ok=%s, err=%s)\n" "$TOT_D" "$OK_D" "$ERR_D"
printf "  taxa de sucesso........: %s%%\n" "$RATE"
printf "  tempo até recuperar....: %s\n" "$RECOVERED"
echo
printf "  tempo de resposta (ms) — FORA da falha (baseline):\n"
printf "     %s\n" "$(lat_line "$BASECAP")"
printf "  tempo de resposta (ms) — DURANTE a falha (só ops OK; ops com erro não têm latência):\n"
printf "     %s\n" "$(lat_line "$LOGCAP")"
printf "     nota: durante a falha, requisições que deram timeout/Unavailable viram ERRO\n"
printf "           (ver taxa acima) e NÃO entram no percentil — por isso compare latência\n"
printf "           SEMPRE junto com a taxa de erro, nunca isolada.\n"
echo
printf "  motivos dos erros (durante a falha):\n"
err_reasons "$LOGCAP"
rm -f "$LOGCAP" "$BASECAP"
echo
if [ "$N" -le 1 ]; then
  if [ "$ERR_D" -eq 0 ]; then
    echo "  VEREDITO: PASS — 1 nó fora, RF=3/LOCAL_QUORUM manteve 0 erros. Tolerância OK."
  else
    echo "  VEREDITO: ATENÇÃO — houve $ERR_D erro(s) com só 1 nó fora (blips de failover?)."
  fi
else
  echo "  VEREDITO: informativo — com N=$N (>1) e RF=3, partições cujas 2 réplicas"
  echo "            caíram perdem quórum e ESSAS operações falham. err=$ERR_D é esperado."
fi
hr
