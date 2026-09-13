#!/usr/bin/env python3
"""
Gerador de carga para o Apache Cassandra — foco em DEMONSTRAR TOLERÂNCIA A FALHAS.

Ideia da demo:
  1) Suba esta app (1+ réplicas). Ela dispara escritas/leituras contínuas em
     LOCAL_QUORUM contra o Service `cassandra-client:9042`.
  2) Em outro terminal, derrube um nó do anel (ex: `make kill-demo`).
  3) Observe no LOG desta app, em tempo real:
       - a linha  ">>> HOST DOWN <ip>"  exatamente quando o nó cai;
       - o placar continuar com  err=0  (RF=3 => 2 de 3 réplicas bastam);
       - a linha  ">>> HOST UP <ip>"    quando o StatefulSet recria o nó.

Config via variáveis de ambiente (ver DEFAULTS abaixo).
"""
import os
import sys
import time
import uuid
import random
import signal
import string
import threading
from collections import deque, Counter
from datetime import datetime, timezone

from cassandra import ConsistencyLevel
from cassandra.cluster import Cluster, ExecutionProfile, EXEC_PROFILE_DEFAULT, NoHostAvailable
from cassandra.policies import (
    DCAwareRoundRobinPolicy,
    TokenAwarePolicy,
    ConstantReconnectionPolicy,
)

# ----------------------------- Configuração --------------------------------- #
def _env(k, d): return os.environ.get(k, d)

CONTACT_POINTS   = _env("CONTACT_POINTS", "cassandra-client").split(",")
PORT             = int(_env("PORT", "9042"))
KEYSPACE         = _env("KEYSPACE", "sd_demo")
LOCAL_DC         = _env("LOCAL_DC", "dc1")
REPL_FACTOR      = int(_env("REPL_FACTOR", "3"))            # RF do keyspace (auto-cria)
CONSISTENCY_NAME = _env("CONSISTENCY", "LOCAL_QUORUM").upper()
CONCURRENCY      = int(_env("CONCURRENCY", "32"))          # requisições em voo
READ_RATIO       = float(_env("READ_RATIO", "0.3"))        # fração de leituras
BUCKETS          = int(_env("BUCKETS", "64"))             # nº de partições
PAYLOAD_BYTES    = int(_env("PAYLOAD_BYTES", "200"))
REPORT_INTERVAL  = float(_env("REPORT_INTERVAL", "2.0"))  # segundos entre placares
REQUEST_TIMEOUT  = float(_env("REQUEST_TIMEOUT", "5.0"))
DURATION_SECONDS = int(_env("DURATION_SECONDS", "0"))      # 0 = roda para sempre
# Emite, a cada janela, uma linha "#LAT <ms> <ms> ..." com as amostras CRUAS de
# latência. É isso que permite ao run-test.sh calcular o percentil CORRETO do
# período inteiro (juntando as amostras) em vez de tirar média de percentis —
# média de percentis é estatisticamente inválida (p50 <= p95 <= p99 só vale
# DENTRO de uma janela). A linha começa com '#' para ser fácil de filtrar no log.
EMIT_LAT_SAMPLES = _env("EMIT_LAT_SAMPLES", "1") not in ("0", "false", "False", "")

_CL = {
    "ANY": ConsistencyLevel.ANY, "ONE": ConsistencyLevel.ONE,
    "TWO": ConsistencyLevel.TWO, "THREE": ConsistencyLevel.THREE,
    "QUORUM": ConsistencyLevel.QUORUM, "ALL": ConsistencyLevel.ALL,
    "LOCAL_ONE": ConsistencyLevel.LOCAL_ONE,
    "LOCAL_QUORUM": ConsistencyLevel.LOCAL_QUORUM,
    "EACH_QUORUM": ConsistencyLevel.EACH_QUORUM,
}
CONSISTENCY = _CL.get(CONSISTENCY_NAME, ConsistencyLevel.LOCAL_QUORUM)
PAYLOAD = "".join(random.choices(string.ascii_letters + string.digits, k=PAYLOAD_BYTES))

def log(msg):
    print(f"{datetime.now().strftime('%H:%M:%S')}  {msg}", flush=True)

# --------------------------- Estado / métricas ------------------------------ #
class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.ok = 0
        self.err = 0
        self.ok_total = 0
        self.err_total = 0
        self.err_kinds = Counter()      # tipo de erro na janela
        self.lat_ms = deque(maxlen=5000)  # amostras de latência da janela
    def record_ok(self, dt_ms):
        with self.lock:
            self.ok += 1; self.ok_total += 1; self.lat_ms.append(dt_ms)
    def record_err(self, kind):
        with self.lock:
            self.err += 1; self.err_total += 1; self.err_kinds[kind] += 1
    def snapshot_and_reset(self):
        with self.lock:
            ok, err = self.ok, self.err
            kinds = dict(self.err_kinds)
            lats = sorted(self.lat_ms)
            self.ok = 0; self.err = 0; self.err_kinds.clear(); self.lat_ms.clear()
            return ok, err, kinds, lats, self.ok_total, self.err_total

STATS = Stats()
RUNNING = threading.Event(); RUNNING.set()

def _pct(sorted_list, p):
    if not sorted_list: return 0.0
    i = min(len(sorted_list) - 1, int(round((p / 100.0) * (len(sorted_list) - 1))))
    return sorted_list[i]

# ------------------- Listener de subida/queda de nós ------------------------ #
# É este listener que faz a demo de falha "aparecer" no log no instante certo.
class RingWatcher:
    def __init__(self, cluster): self.cluster = cluster
    def _live(self):
        hosts = self.cluster.metadata.all_hosts()
        return sum(1 for h in hosts if h.is_up), len(hosts)
    def on_up(self, host):
        up, total = self._live()
        log(f">>> HOST UP   {host.address}   (nós vivos: {up}/{total})")
    def on_down(self, host):
        up, total = self._live()
        log(f">>> HOST DOWN {host.address}   (nós vivos: {up}/{total})  <== FALHA DETECTADA")
    def on_add(self, host):
        log(f">>> HOST ADD  {host.address}")
    def on_remove(self, host):
        log(f">>> HOST REMOVE {host.address}")

# ------------------------------ Conexão ------------------------------------- #
def connect_with_retry():
    profile = ExecutionProfile(
        # TokenAware + DCAware: o driver roteia para as réplicas certas e, quando
        # um nó cai, remaneja as conexões automaticamente (tolerância no cliente).
        load_balancing_policy=TokenAwarePolicy(DCAwareRoundRobinPolicy(local_dc=LOCAL_DC)),
        consistency_level=CONSISTENCY,
        request_timeout=REQUEST_TIMEOUT,
    )
    attempt = 0
    while RUNNING.is_set():
        attempt += 1
        try:
            cluster = Cluster(
                contact_points=CONTACT_POINTS,
                port=PORT,
                execution_profiles={EXEC_PROFILE_DEFAULT: profile},
                reconnection_policy=ConstantReconnectionPolicy(delay=2.0, max_attempts=None),
            )
            session = cluster.connect()
            log(f"Conectado ao cluster '{cluster.metadata.cluster_name}' "
                f"(contact_points={CONTACT_POINTS})")
            return cluster, session
        except Exception as e:
            log(f"[conexão] tentativa {attempt} falhou: {type(e).__name__}: {e} — retry em 3s")
            time.sleep(3)
    sys.exit(0)

def ensure_schema(session):
    session.execute(
        f"CREATE KEYSPACE IF NOT EXISTS {KEYSPACE} WITH replication = "
        f"{{'class':'NetworkTopologyStrategy','{LOCAL_DC}':{REPL_FACTOR}}}"
    )
    session.set_keyspace(KEYSPACE)
    session.execute(
        "CREATE TABLE IF NOT EXISTS eventos ("
        "  id uuid, bucket int, ts timestamp, payload text,"
        "  PRIMARY KEY ((bucket), ts, id)"
        ") WITH CLUSTERING ORDER BY (ts DESC)"
    )
    log(f"Schema pronto: keyspace={KEYSPACE} RF={LOCAL_DC}:{REPL_FACTOR}, tabela=eventos")

# ------------------------------- Workload ----------------------------------- #
def run_workload(session):
    ins = session.prepare("INSERT INTO eventos (bucket, ts, id, payload) VALUES (?, ?, ?, ?)")
    sel = session.prepare("SELECT id FROM eventos WHERE bucket = ? LIMIT 1")
    sem = threading.Semaphore(CONCURRENCY)

    def done_ok(_result, t0):
        sem.release(); STATS.record_ok((time.perf_counter() - t0) * 1000.0)
    def done_err(exc, t0):
        sem.release(); STATS.record_err(type(exc).__name__)

    while RUNNING.is_set():
        sem.acquire()
        if not RUNNING.is_set():
            sem.release(); break
        t0 = time.perf_counter()
        try:
            if random.random() < READ_RATIO:
                fut = session.execute_async(sel, (random.randrange(BUCKETS),))
            else:
                fut = session.execute_async(
                    ins, (random.randrange(BUCKETS),
                          datetime.now(timezone.utc), uuid.uuid4(), PAYLOAD))
            fut.add_callbacks(callback=done_ok, callback_args=(t0,),
                              errback=done_err, errback_args=(t0,))
        except NoHostAvailable as e:
            sem.release(); STATS.record_err("NoHostAvailable"); time.sleep(0.2)
        except Exception as e:
            sem.release(); STATS.record_err(type(e).__name__); time.sleep(0.05)

# ------------------------------ Reporter ------------------------------------ #
def run_reporter(cluster):
    t_start = time.perf_counter()
    while RUNNING.is_set():
        time.sleep(REPORT_INTERVAL)
        ok, err, kinds, lats, ok_t, err_t = STATS.snapshot_and_reset()
        rps = (ok + err) / REPORT_INTERVAL
        hosts = cluster.metadata.all_hosts()
        live = sum(1 for h in hosts if h.is_up)
        elapsed = int(time.perf_counter() - t_start)
        errtxt = ""
        if kinds:
            errtxt = " | erros=" + ",".join(f"{k}:{v}" for k, v in sorted(kinds.items()))
        log(f"[t+{elapsed:>4}s] janela: ok={ok:<5} err={err:<3} | {rps:6.0f} op/s | "
            f"lat ms p50={_pct(lats,50):5.1f} p95={_pct(lats,95):5.1f} p99={_pct(lats,99):6.1f} | "
            f"nós_vivos={live}/{len(hosts)} | TOTAL ok={ok_t} err={err_t}{errtxt}")
        # Amostras cruas da janela para agregação correta a jusante (ver EMIT_LAT_SAMPLES).
        # Impressas sem timestamp para começarem em '#LAT' (filtrável por ^#LAT).
        if EMIT_LAT_SAMPLES and lats:
            print("#LAT " + " ".join(f"{v:.1f}" for v in lats), flush=True)

# ------------------------------- Main --------------------------------------- #
def main():
    def _stop(signum, _frame):
        log(f"Sinal {signum} recebido — encerrando com graça...")
        RUNNING.clear()
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    log(f"loadgen iniciando: CL={CONSISTENCY_NAME} concurrency={CONCURRENCY} "
        f"read_ratio={READ_RATIO} buckets={BUCKETS} duration={DURATION_SECONDS or '∞'}s")
    cluster, session = connect_with_retry()
    cluster.register_listener(RingWatcher(cluster))
    ensure_schema(session)

    rep = threading.Thread(target=run_reporter, args=(cluster,), daemon=True)
    rep.start()

    if DURATION_SECONDS > 0:
        threading.Timer(DURATION_SECONDS, RUNNING.clear).start()

    try:
        run_workload(session)
    finally:
        RUNNING.clear()
        time.sleep(0.5)
        _, _, _, _, ok_t, err_t = STATS.snapshot_and_reset()
        total = ok_t + err_t
        rate = (100.0 * ok_t / total) if total else 100.0
        log(f"=== RESUMO FINAL: ok={ok_t} err={err_t} sucesso={rate:.3f}% ===")
        try: cluster.shutdown()
        except Exception: pass

if __name__ == "__main__":
    main()
