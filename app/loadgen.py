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
BUCKETS          = int(_env("BUCKETS", "64"))             # nº de partições
# Tamanho do pool de chaves já escritas. UPDATE e DELETE precisam de uma linha
# que EXISTA; o pool guarda as PKs das últimas inserções para servirem de alvo.
KEY_POOL_SIZE    = int(_env("KEY_POOL_SIZE", "5000"))
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

def _rand_payload():
    return "".join(random.choices(string.ascii_letters + string.digits, k=PAYLOAD_BYTES))

PAYLOAD     = _rand_payload()   # usado no INSERT
PAYLOAD_ALT = _rand_payload()   # usado no UPDATE — diferente, para a escrita ser real

# --------------------------- Mix de operações ------------------------------- #
# OP_MIX define a proporção entre as 4 operações. Os pesos são NORMALIZADOS,
# então "25,25,25,25" e "1,1,1,1" dão no mesmo.
#
#   OP_MIX="insert=25,read=25,update=25,delete=25"   (default: 25% cada)
#
# Sobre UPDATE no Cassandra: não existe read-modify-write — UPDATE e INSERT são
# o MESMO caminho de escrita (upsert). Ter os dois no mix não exercita código
# diferente do servidor; serve para o perfil de carga espelhar uma aplicação
# real. Já o DELETE é de fato diferente: escreve uma TOMBSTONE (ver
# gc_grace_seconds em ensure_schema).
_OP_ALIASES = {
    "insert": "insert", "ins": "insert", "write": "insert", "escrita": "insert",
    "read": "read", "rd": "read", "select": "read", "leitura": "read",
    "update": "update", "upd": "update",
    "delete": "delete", "del": "delete",
}

def _parse_mix(spec):
    w = {"insert": 0.0, "read": 0.0, "update": 0.0, "delete": 0.0}
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        name, _, value = part.partition("=")
        key = _OP_ALIASES.get(name.strip().lower())
        if key is None:
            raise SystemExit(f"OP_MIX: operação desconhecida {name!r} "
                             f"(use insert/read/update/delete)")
        w[key] += float(value)
    total = sum(w.values())
    if total <= 0:
        raise SystemExit("OP_MIX: a soma dos pesos precisa ser > 0")
    return {k: v / total for k, v in w.items()}

_MIX_SPEC = os.environ.get("OP_MIX")
if _MIX_SPEC is None and "READ_RATIO" in os.environ:
    # Compatibilidade com manifestos antigos, de quando só havia leitura/escrita.
    _r = float(os.environ["READ_RATIO"])
    _MIX_SPEC = f"read={_r},insert={1.0 - _r}"
OP_MIX = _parse_mix(_MIX_SPEC or "insert=25,read=25,update=25,delete=25")

_OP_NAMES = ["insert", "read", "update", "delete"]
_OP_CUM, _acc = [], 0.0
for _n in _OP_NAMES:
    _acc += OP_MIX[_n]
    _OP_CUM.append(_acc)
_OP_CUM[-1] = 1.0            # blinda contra erro de arredondamento
MIX_TXT = " ".join(f"{n}={OP_MIX[n]*100:.0f}%" for n in _OP_NAMES)
_OP_LABEL = {"insert": "ins", "read": "rd", "update": "upd", "delete": "del"}

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
        self.ok_ops = Counter()         # sucessos por operação na janela
        self.err_ops = Counter()        # falhas por operação na janela
        self.lat_ms = deque(maxlen=5000)  # amostras de latência da janela
    def record_ok(self, op, dt_ms):
        with self.lock:
            self.ok += 1; self.ok_total += 1; self.lat_ms.append(dt_ms)
            self.ok_ops[op] += 1
    def record_err(self, op, kind):
        with self.lock:
            self.err += 1; self.err_total += 1; self.err_kinds[kind] += 1
            self.err_ops[op] += 1
    def snapshot_and_reset(self):
        with self.lock:
            ok, err = self.ok, self.err
            kinds = dict(self.err_kinds)
            ok_ops, err_ops = dict(self.ok_ops), dict(self.err_ops)
            lats = sorted(self.lat_ms)
            self.ok = 0; self.err = 0; self.err_kinds.clear(); self.lat_ms.clear()
            self.ok_ops.clear(); self.err_ops.clear()
            return ok, err, kinds, lats, self.ok_total, self.err_total, ok_ops, err_ops

STATS = Stats()
RUNNING = threading.Event(); RUNNING.set()

class KeyPool:
    """Pool limitado de chaves primárias já gravadas, alvo de UPDATE e DELETE.

    Acessado pela thread do workload E pelas threads de callback do driver, daí
    o lock. Quando enche, uma posição aleatória é sobrescrita (amostragem
    simples) — não interessa manter histórico, só ter alvos válidos à mão.
    """
    def __init__(self, cap):
        self._keys = []
        self._cap = cap
        self._lock = threading.Lock()

    def add(self, key):
        with self._lock:
            if len(self._keys) < self._cap:
                self._keys.append(key)
            else:
                self._keys[random.randrange(self._cap)] = key

    def pick(self):
        """Sorteia uma chave SEM remover (UPDATE não destrói a linha)."""
        with self._lock:
            return random.choice(self._keys) if self._keys else None

    def pop(self):
        """Sorteia e REMOVE (DELETE: a linha deixa de existir).

        Troca com o último antes de remover, para não pagar O(n) do list.pop(i).
        """
        with self._lock:
            if not self._keys:
                return None
            i = random.randrange(len(self._keys))
            self._keys[i], self._keys[-1] = self._keys[-1], self._keys[i]
            return self._keys.pop()

    def __len__(self):
        with self._lock:
            return len(self._keys)

KEYS = KeyPool(KEY_POOL_SIZE)

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
    # gc_grace_seconds: por quanto tempo as TOMBSTONES (marcas de DELETE) ficam
    # guardadas antes de a compactação poder descartá-las. O default do Cassandra
    # é 10 dias — pensado para dar tempo de um nó voltar de uma longa ausência e
    # receber o hint da remoção; sem isso a linha apagada "ressuscitaria".
    #
    # Num gerador de carga com 25% de DELETE isso é inviável: as tombstones se
    # acumulam nas mesmas 64 partições e o SELECT (que varre do ts mais novo
    # para trás) passa a pular montanhas delas, inflando a latência de leitura e,
    # em execução longa, estourando em TombstoneOverwhelmingException.
    #
    # 1 hora é folgado para a janela de uma demo (hints são entregues em
    # segundos) e curto o bastante para a compactação limpar durante a sessão.
    session.execute(
        "CREATE TABLE IF NOT EXISTS eventos ("
        "  id uuid, bucket int, ts timestamp, payload text,"
        "  PRIMARY KEY ((bucket), ts, id)"
        ") WITH CLUSTERING ORDER BY (ts DESC)"
        "   AND gc_grace_seconds = 3600"
    )
    log(f"Schema pronto: keyspace={KEYSPACE} RF={LOCAL_DC}:{REPL_FACTOR}, tabela=eventos")

# ------------------------------- Workload ----------------------------------- #
def run_workload(session):
    ins = session.prepare(
        "INSERT INTO eventos (bucket, ts, id, payload) VALUES (?, ?, ?, ?)")
    sel = session.prepare(
        "SELECT id FROM eventos WHERE bucket = ? LIMIT 1")
    upd = session.prepare(
        "UPDATE eventos SET payload = ? WHERE bucket = ? AND ts = ? AND id = ?")
    dlt = session.prepare(
        "DELETE FROM eventos WHERE bucket = ? AND ts = ? AND id = ?")
    stmt = {"insert": ins, "read": sel, "update": upd, "delete": dlt}
    sem = threading.Semaphore(CONCURRENCY)

    def done_ok(_result, t0, op, key):
        sem.release()
        STATS.record_ok(op, (time.perf_counter() - t0) * 1000.0)
        # Só entra no pool o que foi REALMENTE gravado.
        if op == "insert":
            KEYS.add(key)

    def fail(op, key, kind):
        sem.release()
        STATS.record_err(op, kind)
        # DELETE que não completou => a linha continua existindo. Devolver a
        # chave ao pool evita que o pool encolha por causa de falhas e mantém o
        # alvo disponível para uma próxima tentativa.
        if op == "delete" and key is not None:
            KEYS.add(key)

    def done_err(exc, t0, op, key):
        fail(op, key, type(exc).__name__)

    def new_key():
        return (random.randrange(BUCKETS), datetime.now(timezone.utc), uuid.uuid4())

    def pick():
        """Sorteia a operação e resolve o alvo -> (op, chave, argumentos).

        UPDATE e DELETE exigem uma linha que já exista. Enquanto o pool estiver
        vazio (os primeiros instantes, ou logo após uma rajada de deletes) eles
        viram INSERT: assim o gerador nunca fica ocioso e o pool se reabastece
        sozinho. O contador reflete a operação EFETIVAMENTE executada, não a
        sorteada — por isso o mix impresso pode desviar de 25% no começo.
        """
        op = random.choices(_OP_NAMES, cum_weights=_OP_CUM, k=1)[0]

        if op == "read":
            return op, None, (random.randrange(BUCKETS),)
        if op == "insert":
            k = new_key()
            return op, k, (k[0], k[1], k[2], PAYLOAD)

        key = KEYS.pop() if op == "delete" else KEYS.pick()
        if key is None:
            k = new_key()
            return "insert", k, (k[0], k[1], k[2], PAYLOAD)
        if op == "update":
            return op, key, (PAYLOAD_ALT, key[0], key[1], key[2])
        return op, key, (key[0], key[1], key[2])

    while RUNNING.is_set():
        sem.acquire()
        if not RUNNING.is_set():
            sem.release(); break
        op, key, args = pick()
        t0 = time.perf_counter()
        try:
            fut = session.execute_async(stmt[op], args)
            fut.add_callbacks(callback=done_ok, callback_args=(t0, op, key),
                              errback=done_err, errback_args=(t0, op, key))
        except NoHostAvailable:
            fail(op, key, "NoHostAvailable"); time.sleep(0.2)
        except Exception as e:
            fail(op, key, type(e).__name__); time.sleep(0.05)

# ------------------------------ Reporter ------------------------------------ #
def run_reporter(cluster):
    t_start = time.perf_counter()
    while RUNNING.is_set():
        time.sleep(REPORT_INTERVAL)
        ok, err, kinds, lats, ok_t, err_t, ok_ops, err_ops = STATS.snapshot_and_reset()
        rps = (ok + err) / REPORT_INTERVAL
        hosts = cluster.metadata.all_hosts()
        live = sum(1 for h in hosts if h.is_up)
        elapsed = int(time.perf_counter() - t_start)
        errtxt = ""
        if kinds:
            errtxt = " | erros=" + ",".join(f"{k}:{v}" for k, v in sorted(kinds.items()))
        # Quais operações falharam — sai só quando há falha, para não poluir o
        # placar no caso normal (err=0). Nome distinto de "erros=" de propósito:
        # o run-test.sh casa 'erros=' e não pode confundir os dois campos.
        if err_ops:
            errtxt += " | err_op=" + ",".join(f"{k}:{v}" for k, v in sorted(err_ops.items()))
        # Tentativas por operação na janela (ok + falhas). Serve para conferir
        # ao vivo que o mix configurado está sendo respeitado.
        mixtxt = " ".join(f"{_OP_LABEL[n]}={ok_ops.get(n, 0) + err_ops.get(n, 0)}"
                          for n in _OP_NAMES)
        log(f"[t+{elapsed:>4}s] janela: ok={ok:<5} err={err:<3} | {rps:6.0f} op/s | "
            f"lat ms p50={_pct(lats,50):5.1f} p95={_pct(lats,95):5.1f} p99={_pct(lats,99):6.1f} | "
            f"mix {mixtxt} | pool={len(KEYS)} | "
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
        f"buckets={BUCKETS} duration={DURATION_SECONDS or '∞'}s")
    log(f"mix de operações: {MIX_TXT}  (pool de chaves p/ UPDATE/DELETE: {KEY_POOL_SIZE})")
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
        _, _, _, _, ok_t, err_t, _, _ = STATS.snapshot_and_reset()
        total = ok_t + err_t
        rate = (100.0 * ok_t / total) if total else 100.0
        log(f"=== RESUMO FINAL: ok={ok_t} err={err_t} sucesso={rate:.3f}% ===")
        try: cluster.shutdown()
        except Exception: pass

if __name__ == "__main__":
    main()
