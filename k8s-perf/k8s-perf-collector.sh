#!/usr/bin/env bash
#
# k8s-perf-collector.sh
#
# Capture container, namespace, node and Kubernetes API performance
# measurements - together with the messages, timeouts, errors and failure
# conditions behind them - from any vanilla (conformant) Kubernetes cluster,
# and turn them into a Markdown report, a JSON summary and CSV tables.
#
# Needs only bash (>= 4.2), kubectl and jq (>= 1.6) on the machine running it.
# Nothing is installed in the cluster. Data sources:
#   * core API objects: pods, events, nodes, workloads, PVCs, quotas, services
#   * kube-apiserver /metrics, /livez and /readyz
#   * each kubelet's Summary API, cAdvisor, prober and kubelet metrics, reached
#     through the API server's node proxy (metrics-server is optional and only
#     used as a fallback for CPU/memory usage)
#   * client-side latency probes timed by client-go (kubectl -v=6)
#
# Run with --help for all options and --dry-run to print every request it
# would make without contacting the cluster.

set -uo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME=${0##*/}

# ------------------------------------------------------------------ options --
OUT_DIR=""
NAMESPACES=()
CONTEXT=""
KUBECONFIG_FILE=""
KUBECTL_EXTRA=()
WINDOW=30
PROBE_SAMPLES=10
PROBE_ENDPOINTS_EXTRA=()
REQUEST_TIMEOUT=15
PARALLEL=4
MAX_NODES=0
SKIP_NODE_STATS=false
SKIP_APISERVER_METRICS=false
WRITE_PROBE=false
WRITE_PROBE_NS=default
KEEP_RAW_METRICS=false
REDACT=true
ARCHIVE=false
DRY_RUN=""
ANALYZE_ONLY=""
FAIL_ON=none
VERBOSE=false

# Failure-condition thresholds; override with --threshold NAME=VALUE.
declare -A TH=(
  [restart_count]=3        # container restarts before HighRestartCount
  [restart_recent_minutes]=15 # ...and CrashLooping when the last one is this recent
  [throttle_min_periods]=100  # CFS periods (x100ms) needed before judging throttling
  [mem_limit_pct]=90       # working set as % of memory limit (OOM risk)
  [cpu_throttle_pct]=25    # % of CFS periods throttled
  [pending_minutes]=5      # scheduled pod still Pending after N minutes
  [api_slow_ms]=1000       # client-side p99 API latency
  [etcd_slow_ms]=250       # etcd request p99 latency
  [apf_wait_ms]=1000       # API Priority & Fairness queue wait p99
  [webhook_slow_ms]=1000   # admission webhook p99 latency
  [pleg_slow_ms]=1000      # kubelet PLEG relist p99
  [node_cpu_pct]=90        # node CPU usage as % of allocatable
  [node_mem_pct]=90        # node memory working set as % of allocatable
  [node_disk_pct]=85       # node / image filesystem usage
  [node_pid_pct]=80        # node PIDs in use as % of max
  [volume_pct]=90          # pod volume bytes or inodes used
  [quota_pct]=90           # ResourceQuota usage
)

# ------------------------------------------------------------ runtime state --
TMP_DIR=""
LOG_FILE=""
CALLS_TSV=""
RAW=""
CLOCK=seconds
TIMEOUT_BIN=""
HAVE_WAIT_N=false
KUBECTL=()
CTX_NAME=""
RUN_ID=""
STARTED_AT=""
STARTED_EPOCH=0
SCRAPE_START_MS=0
SCRAPE_END_MS=0
LAST_CALL_STATUS=""
LAST_CALL_MSG=""
PLAN_COUNT=0

# Metric families kept from each Prometheus endpoint (everything else is
# dropped right after the scrape unless --keep-raw-metrics is given).
readonly APISERVER_FAMILIES='^(apiserver_request_total|apiserver_request_duration_seconds_bucket|apiserver_request_terminations_total|apiserver_request_aborts_total|apiserver_flowcontrol_rejected_requests_total|apiserver_flowcontrol_request_wait_duration_seconds_bucket|apiserver_flowcontrol_current_inqueue_requests|apiserver_current_inflight_requests|apiserver_longrunning_requests|etcd_request_duration_seconds_bucket|etcd_request_errors_total|apiserver_admission_webhook_admission_duration_seconds_bucket|apiserver_admission_webhook_rejection_count|apiserver_admission_webhook_fail_open_count|apiserver_resource_objects|apiserver_storage_objects|apiserver_tls_handshake_errors_total|authentication_attempts|apiserver_watch_events_total|process_resident_memory_bytes|process_cpu_seconds_total|process_start_time_seconds|go_goroutines|kubernetes_build_info)[{ ]'
readonly CADVISOR_FAMILIES='^container_(cpu_cfs_periods_total|cpu_cfs_throttled_periods_total|cpu_cfs_throttled_seconds_total|oom_events_total)[{]'
readonly CADVISOR_EXCLUDE='container=""|container="POD"'
readonly PROBER_FAMILIES='^prober_probe_total[{]'
readonly KUBELET_FAMILIES='^(kubelet_pleg_relist_duration_seconds_bucket|kubelet_runtime_operations_errors_total|kubelet_runtime_operations_duration_seconds_bucket|kubelet_pod_start_duration_seconds_bucket|kubelet_pod_start_sli_duration_seconds_bucket|kubelet_evictions|storage_operation_duration_seconds_count|kubelet_running_pods|kubelet_running_containers|kubernetes_build_info)[{ ]'

# Namespaced object lists: <file name>:<kubectl resource>.
readonly OBJECT_LISTS=(
  "pods:pods"
  "events:events"
  "deployments:deployments.apps"
  "statefulsets:statefulsets.apps"
  "daemonsets:daemonsets.apps"
  "jobs:jobs.batch"
  "pvcs:persistentvolumeclaims"
  "resourcequotas:resourcequotas"
  "services:services"
  "endpointslices:endpointslices.discovery.k8s.io"
  "hpas:horizontalpodautoscalers.autoscaling"
)

# Permissions checked by --dry-run=server: verb|resource|scope|purpose.
readonly RBAC_CHECKS=(
  "get|/version|nonresource|connectivity (required)"
  "get|/livez|nonresource|API liveness checks"
  "get|/readyz|nonresource|API readiness checks"
  "get|/metrics|nonresource|API server metrics"
  "list|nodes|cluster|node conditions and capacity"
  "list|namespaces|cluster|namespace inventory"
  "get|nodes/proxy|cluster|kubelet stats, cAdvisor, probes"
  "list|pods|namespaced|container state (required)"
  "list|events|namespaced|messages and failure events"
  "list|deployments.apps|namespaced|workload status"
  "list|statefulsets.apps|namespaced|workload status"
  "list|daemonsets.apps|namespaced|workload status"
  "list|jobs.batch|namespaced|job failures"
  "list|persistentvolumeclaims|namespaced|storage status"
  "list|resourcequotas|namespaced|quota usage"
  "list|services|namespaced|service endpoints"
  "list|endpointslices.discovery.k8s.io|namespaced|service endpoints"
  "list|horizontalpodautoscalers.autoscaling|namespaced|autoscaler status"
  "list|pods.metrics.k8s.io|namespaced|metrics-server fallback"
  "list|leases.coordination.k8s.io|cluster|lease LIST latency probe"
)

# ------------------------------------------------------------------ logging --
_log() {
  local level=$1 line
  shift
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level] $*"
  [[ -n $LOG_FILE ]] && printf '%s\n' "$line" >>"$LOG_FILE"
  if [[ $level != DEBUG || $VERBOSE == true ]]; then
    printf '%s\n' "$line" >&2
  fi
}
log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { _log DEBUG "$@"; }
die() {
  local code=$1
  shift
  log_error "$*"
  exit "$code"
}

# Reads a heredoc into the named variable.
define() { IFS= read -r -d '' "$1" || true; }

# ---------------------------------------------------------------------- usage --
threshold_names() {
  local -a names
  mapfile -t names < <(printf '%s\n' "${!TH[@]}" | sort)
  printf '%s ' "${names[@]}" | fold -s -w 50 | sed '2,$s/^/                            /'
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Collect container, namespace, node and Kubernetes API performance data plus
messages, timeouts, errors and failure conditions from a vanilla Kubernetes
cluster. Writes report.md, summary.json and csv/*.csv to the output directory.

Target
  --context NAME            kubeconfig context (default: current context)
  --kubeconfig FILE         kubeconfig file (default: \$KUBECONFIG or ~/.kube/config)
  -n, --namespace NS[,NS]   limit to these namespaces (repeatable; default: all)
  --kubectl-arg ARG         extra argument for every kubectl call (repeatable),
                            e.g. --kubectl-arg=--as=system:serviceaccount:ns:sa

Collection
  -o, --output-dir DIR      output directory
                            (default: ./k8s-perf-<context>-<UTC timestamp>)
  -w, --window SECONDS      observation window between the two API server
                            /metrics scrapes; counters are reported as deltas
                            over this window (default: $WINDOW; 0 = cumulative)
  --probe-samples N         client-side latency samples per API endpoint
                            (default: $PROBE_SAMPLES; 0 disables the probes)
  --probe-endpoint NAME=PATH
                            extra API path to latency-probe (repeatable)
  --timeout SECONDS         per-request timeout (default: $REQUEST_TIMEOUT)
  --parallel N              kubelets scraped concurrently (default: $PARALLEL)
  --max-nodes N             scrape at most N kubelets (default: all)
  --skip-node-stats         do not query kubelets through the node proxy
  --skip-apiserver-metrics  do not scrape kube-apiserver /metrics
  --write-probe             also time create/get/patch/delete of a throw-away
                            ConfigMap (the only write the collector can make)
  --write-probe-namespace NS
                            namespace for --write-probe (default: $WRITE_PROBE_NS)
  --keep-raw-metrics        keep full Prometheus scrapes (gzipped); by default
                            only the metric families the analysis uses are kept
  --no-redact               keep env values, managedFields and last-applied
                            annotations in the raw object dumps
  --archive                 also write <output-dir>.tar.gz

Analysis
  --threshold NAME=VALUE    override a failure threshold (repeatable). Names:
                            $(threshold_names)
  --fail-on LEVEL           exit 3 when findings at LEVEL or worse exist:
                            none (default), warning, critical
  --analyze-only DIR        re-run the analysis on an existing output directory
                            without contacting the cluster

Modes
  --dry-run[=client|server] client (default): print every request that would
                            be made and contact nothing. server: also check
                            connectivity and RBAC (SelfSubjectAccessReview) and size
                            the cluster - still collects nothing
  -v, --verbose             debug logging
  -h, --help                show this help
  --version                 print the version

Exit codes: 0 ok, 1 usage or prerequisite error, 2 API server unreachable,
            3 findings at or above the --fail-on level
EOF
}

# ------------------------------------------------------------ argument parsing --
need_arg() { (($# >= 2)) && [[ -n $2 ]] || die 1 "option $1 needs a value"; }
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

parse_args() {
  local -a ns
  local key value
  while (($#)); do
    case $1 in
      --dry-run) DRY_RUN=client; shift; continue ;;
      --dry-run=*) DRY_RUN=${1#*=}; shift; continue ;;
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}" ;;
    esac
    case $1 in
      -o | --output-dir) need_arg "$@"; OUT_DIR=$2; shift 2 ;;
      -n | --namespace)
        need_arg "$@"
        IFS=, read -r -a ns <<<"$2"
        NAMESPACES+=("${ns[@]}")
        shift 2
        ;;
      --context) need_arg "$@"; CONTEXT=$2; shift 2 ;;
      --kubeconfig) need_arg "$@"; KUBECONFIG_FILE=$2; shift 2 ;;
      --kubectl-arg) need_arg "$@"; KUBECTL_EXTRA+=("$2"); shift 2 ;;
      -w | --window) need_arg "$@"; WINDOW=$2; shift 2 ;;
      --probe-samples) need_arg "$@"; PROBE_SAMPLES=$2; shift 2 ;;
      --probe-endpoint)
        need_arg "$@"
        [[ $2 =~ ^[A-Za-z0-9_.-]+=/ ]] || die 1 "--probe-endpoint expects NAME=/api/path, got '$2'"
        PROBE_ENDPOINTS_EXTRA+=("$2")
        shift 2
        ;;
      --timeout) need_arg "$@"; REQUEST_TIMEOUT=$2; shift 2 ;;
      --parallel) need_arg "$@"; PARALLEL=$2; shift 2 ;;
      --max-nodes) need_arg "$@"; MAX_NODES=$2; shift 2 ;;
      --skip-node-stats) SKIP_NODE_STATS=true; shift ;;
      --skip-apiserver-metrics) SKIP_APISERVER_METRICS=true; shift ;;
      --write-probe) WRITE_PROBE=true; shift ;;
      --write-probe-namespace) need_arg "$@"; WRITE_PROBE_NS=$2; shift 2 ;;
      --keep-raw-metrics) KEEP_RAW_METRICS=true; shift ;;
      --no-redact) REDACT=false; shift ;;
      --archive) ARCHIVE=true; shift ;;
      --threshold)
        need_arg "$@"
        key=${2%%=*} value=${2#*=}
        [[ -n ${TH[$key]+set} ]] || die 1 "unknown threshold '$key'; valid: $(printf '%s ' "${!TH[@]}")"
        [[ $value =~ ^[0-9]+(\.[0-9]+)?$ ]] || die 1 "threshold $key must be a number, got '$value'"
        TH[$key]=$value
        shift 2
        ;;
      --fail-on) need_arg "$@"; FAIL_ON=$2; shift 2 ;;
      --analyze-only) need_arg "$@"; ANALYZE_ONLY=$2; shift 2 ;;
      -v | --verbose) VERBOSE=true; shift ;;
      -h | --help) usage; exit 0 ;;
      --version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
      *) die 1 "unknown argument: $1 (see --help)" ;;
    esac
  done

  is_uint "$WINDOW" || die 1 "--window must be a whole number of seconds"
  is_uint "$PROBE_SAMPLES" || die 1 "--probe-samples must be a non-negative integer"
  { is_uint "$REQUEST_TIMEOUT" && ((REQUEST_TIMEOUT > 0)); } || die 1 "--timeout must be a positive integer"
  { is_uint "$PARALLEL" && ((PARALLEL > 0)); } || die 1 "--parallel must be a positive integer"
  is_uint "$MAX_NODES" || die 1 "--max-nodes must be a non-negative integer"
  case $DRY_RUN in "" | client | server) ;; *) die 1 "--dry-run must be 'client' or 'server'" ;; esac
  case $FAIL_ON in none | warning | critical) ;; *) die 1 "--fail-on must be none, warning or critical" ;; esac
  local n
  for n in ${NAMESPACES[@]+"${NAMESPACES[@]}"}; do
    [[ $n =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 1 "invalid namespace name '$n'"
  done
}

# --------------------------------------------------------------------- helpers --
check_prereqs() {
  ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))) ||
    die 1 "bash >= 4.2 is required (found $BASH_VERSION)"
  ((BASH_VERSINFO[0] > 4 || BASH_VERSINFO[1] >= 3)) && HAVE_WAIT_N=true
  local tool missing=()
  for tool in jq awk grep sed sort date mktemp wc tr head fold; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [[ -n $ANALYZE_ONLY ]] || command -v kubectl >/dev/null 2>&1 || missing+=(kubectl)
  if ((${#missing[@]})); then
    [[ $DRY_RUN == client ]] || die 1 "missing required tools: ${missing[*]}"
    log_warn "missing required tools: ${missing[*]} (continuing because this is a dry run)"
  fi
  if command -v jq >/dev/null 2>&1; then
    local jqv
    jqv=$(jq --version 2>/dev/null)
    [[ $jqv =~ ^jq-1\.[0-5]([^0-9]|$) ]] && die 1 "jq >= 1.6 is required (found $jqv)"
  fi
  TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
  [[ -n $TIMEOUT_BIN ]] || log_debug "no timeout(1) found; relying on kubectl --request-timeout only"
}

init_clock() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    CLOCK=epochrealtime
  elif [[ $(date +%s%3N 2>/dev/null) =~ ^[0-9]+$ ]]; then
    CLOCK=gnudate
  else
    CLOCK=seconds
  fi
}

now_ms() {
  case $CLOCK in
    epochrealtime)
      local t=${EPOCHREALTIME/[.,]/}
      printf '%s\n' $((10#$t / 1000))
      ;;
    gnudate) date +%s%3N ;;
    *) printf '%s000\n' "$(date +%s)" ;;
  esac
}

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

json_array() {
  (($#)) || { printf '[]'; return; }
  printf '%s\n' "$@" | jq -R . | jq -sc .
}

thresholds_json() {
  local -a args=()
  local k
  for k in "${!TH[@]}"; do args+=(--argjson "$k" "${TH[$k]}"); done
  jq -ncS "${args[@]}" '$ARGS.named'
}

# Prints FILE if it holds valid JSON, otherwise a temp file containing DEFAULT.
json_or() {
  local f=$1 default=$2 t
  if [[ -s $f ]] && jq empty "$f" >/dev/null 2>&1; then
    printf '%s\n' "$f"
  else
    t=$(mktemp "$TMP_DIR/default.XXXXXX")
    printf '%s\n' "$default" >"$t"
    printf '%s\n' "$t"
  fi
}

text_or_empty() {
  local f=$1
  if [[ -f $f ]]; then printf '%s\n' "$f"; else
    local t
    t=$(mktemp "$TMP_DIR/empty.XXXXXX")
    printf '%s\n' "$t"
  fi
}

quote_cmd() {
  local out="" a
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then out+="$a "; else out+="'${a//\'/\'\\\'\'}' "; fi
  done
  printf '%s' "${out% }"
}

# Inside a pod without a kubeconfig, kubectl only falls back to in-cluster
# credentials when no client flag is overridden - and --request-timeout is an
# override, so it would try localhost:8080 instead. Write an explicit
# kubeconfig for the mounted ServiceAccount (tokenFile follows token rotation).
in_cluster_kubeconfig() {
  local sa=/var/run/secrets/kubernetes.io/serviceaccount
  [[ -z $KUBECONFIG_FILE && -z ${KUBECONFIG:-} && ! -f ${HOME:-/nonexistent}/.kube/config ]] || return 1
  [[ -n ${KUBERNETES_SERVICE_HOST:-} && -n ${KUBERNETES_SERVICE_PORT:-} && -f $sa/token ]] || return 1
  local host=$KUBERNETES_SERVICE_HOST sa_ns=default
  [[ $host == *:* ]] && host="[$host]"
  [[ -f $sa/namespace ]] && sa_ns=$(<"$sa/namespace")
  cat >"$TMP_DIR/in-cluster.kubeconfig" <<KUBECONFIG_EOF
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: https://$host:$KUBERNETES_SERVICE_PORT
    certificate-authority: $sa/ca.crt
users:
- name: service-account
  user:
    tokenFile: $sa/token
contexts:
- name: in-cluster
  context:
    cluster: in-cluster
    user: service-account
    namespace: $sa_ns
current-context: in-cluster
KUBECONFIG_EOF
  KUBECONFIG_FILE="$TMP_DIR/in-cluster.kubeconfig"
  log_debug "running in a pod: using ServiceAccount credentials via $KUBECONFIG_FILE"
}

build_kubectl() {
  in_cluster_kubeconfig || true
  KUBECTL=(kubectl)
  [[ -n $KUBECONFIG_FILE ]] && KUBECTL+=(--kubeconfig "$KUBECONFIG_FILE")
  [[ -n $CONTEXT ]] && KUBECTL+=(--context "$CONTEXT")
  KUBECTL+=(--request-timeout "${REQUEST_TIMEOUT}s")
  KUBECTL+=(${KUBECTL_EXTRA[@]+"${KUBECTL_EXTRA[@]}"})
}

resolve_context() {
  CTX_NAME=$CONTEXT
  if [[ -z $CTX_NAME ]] && command -v kubectl >/dev/null 2>&1; then
    local -a cfg=(kubectl)
    [[ -n $KUBECONFIG_FILE ]] && cfg+=(--kubeconfig "$KUBECONFIG_FILE")
    CTX_NAME=$("${cfg[@]}" config current-context 2>/dev/null || true)
  fi
  [[ -n $CTX_NAME ]] || CTX_NAME="in-cluster"
}

step() {
  if [[ $DRY_RUN == client ]]; then
    printf '\n  %s\n' "$*"
  else
    log_info "== $*"
  fi
}

# ---------------------------------------------------------------- API calls --
# Extracts "<total ms> <request count> <last HTTP status>" from kubectl -v=6
# output. Handles both the structured ("Response" ... milliseconds=N) and the
# legacy ("GET <url> 200 OK in N milliseconds") client-go log formats.
define AWK_HTTP <<'AWK'
/"Response"/ {
  if ($0 ~ /status=""/) failed++
  if (match($0, /status="[0-9]+/)) st = substr($0, RSTART + 8, RLENGTH - 8)
  if (match($0, /milliseconds=[0-9]+/)) { ms += substr($0, RSTART + 13, RLENGTH - 13); n++ }
  next
}
/ in [0-9]+ milliseconds/ {
  if (match($0, / [1-5][0-9][0-9] [A-Za-z][A-Za-z ]* in [0-9]+ milliseconds/)) st = substr($0, RSTART + 1, 3)
  if (match($0, / in [0-9]+ milliseconds/)) { s = substr($0, RSTART + 4); ms += s + 0; n++ }
}
END { printf "%s %d %s %d\n", (n ? ms : "-"), n, (st == "" ? "-" : st), failed }
AWK

# classify_call RC HTTP_STATUS MESSAGE -> ok|timeout|forbidden|unauthorized|
#   not_found|throttled|unreachable|server_error|error
classify_call() {
  local rc=$1 code=$2 msg=$3
  if ((rc == 0)); then echo ok; return; fi
  if ((rc == 124 || rc == 137)); then echo timeout; return; fi
  local re_timeout='context deadline exceeded|client\.timeout|i/o timeout|tls handshake timeout|timed out|timeout awaiting|did not complete within|\(timeout\)|gateway ?timeout'
  local re_forbidden='\(forbidden\)|is forbidden'
  local re_unauth='\(unauthorized\)|must be logged in|provide credentials'
  local re_notfound='\(notfound\)|could not find the requested resource|doesn.t have a resource type'
  local re_throttled='too ?many ?requests'
  local re_unreach='connection refused|was refused|no such host|unable to connect to the server|network is unreachable|no route to host|connection reset'
  local re_server='\(serviceunavailable\)|\(internalerror\)|currently unable to handle|\(badgateway\)'
  local status=error
  shopt -s nocasematch
  case $code in
    401) status=unauthorized ;;
    403) status=forbidden ;;
    404) status=not_found ;;
    408 | 504) status=timeout ;;
    429) status=throttled ;;
    5??) if [[ $msg =~ $re_timeout ]]; then status=timeout; else status=server_error; fi ;;
    *)
      if [[ $msg =~ $re_timeout ]]; then status=timeout
      elif [[ $msg =~ $re_forbidden ]]; then status=forbidden
      elif [[ $msg =~ $re_unauth ]]; then status=unauthorized
      elif [[ $msg =~ $re_notfound ]]; then status=not_found
      elif [[ $msg =~ $re_throttled ]]; then status=throttled
      elif [[ $msg =~ $re_unreach ]]; then status=unreachable
      elif [[ $msg =~ $re_server ]]; then status=server_error
      fi
      ;;
  esac
  shopt -u nocasematch
  echo "$status"
}

plan_line() {
  local id=$1 out=$2
  shift 2
  printf '    %-34s %s\n' "$id" "$(quote_cmd "${KUBECTL[@]}" "$@" -v=6)"
  [[ $out != - ]] && printf '    %-34s -> %s\n' "" "${out#"$OUT_DIR"/}"
  PLAN_COUNT=$((PLAN_COUNT + 1))
}

# api_call PHASE ID TARGET OUTFILE KUBECTL-ARGS...
#   Runs one kubectl invocation with -v=6, times it (wall clock and the HTTP
#   round trip reported by client-go), classifies the outcome and appends a
#   row to meta/calls.tsv. OUTFILE "-" discards stdout. Returns 0 on success.
api_call() {
  local phase=$1 id=$2 target=$3 out=$4
  shift 4
  if [[ $DRY_RUN == client ]]; then
    plan_line "$id" "$out" "$@"
    return 0
  fi
  local errf part rc t0 t1 http_ms http_n http_status http_failed msg notes status bytes=0
  errf="$TMP_DIR/call.$BASHPID.$RANDOM.err"
  if [[ $out == - ]]; then part=/dev/null; else part="$out.part"; fi

  t0=$(now_ms)
  if [[ -n $TIMEOUT_BIN ]]; then
    "$TIMEOUT_BIN" -k 5 "$((REQUEST_TIMEOUT * 4 + 30))" "${KUBECTL[@]}" "$@" -v=6 >"$part" 2>"$errf"
  else
    "${KUBECTL[@]}" "$@" -v=6 >"$part" 2>"$errf"
  fi
  rc=$?
  t1=$(now_ms)

  read -r http_ms http_n http_status http_failed < <(awk "$AWK_HTTP" "$errf")
  [[ $http_ms == - ]] && http_ms=""
  [[ $http_status == - ]] && http_status=""
  if grep -qE '^(Error from server|error: |Unable to connect|The connection to the server)' "$errf"; then
    msg=$(grep -E '^(Error from server|error: |Unable to connect|The connection to the server)' "$errf")
  else
    msg=$(grep -vE '^[IW][0-9]{4} |^Warning: |^[[:space:]]*$' "$errf")
  fi
  msg=$(printf '%s' "$msg" | head -c 3000 | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
  notes=""
  grep -q 'client-side throttling' "$errf" && notes+="client-side-throttling;"
  ((rc == 0 && ${http_failed:-0} > 0)) && notes+="recovered-after-${http_failed}-failed-attempt(s);"
  grep -q '^Warning: ' "$errf" && notes+="server-warning: $(grep -m1 '^Warning: ' "$errf" | cut -c10-160 | tr '\t' ' ');"
  status=$(classify_call "$rc" "$http_status" "$msg")

  if [[ $out != - ]]; then
    if ((rc == 0)); then
      mv -f "$part" "$out"
      bytes=$(wc -c <"$out" | tr -d ' ')
    else
      rm -f "$part"
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ts_utc)" "$phase" "$id" "$target" "$status" "$rc" "$((t1 - t0))" "$http_ms" \
    "${http_n:-0}" "$http_status" "$bytes" "$notes" "${msg:0:600}" >>"$CALLS_TSV"
  LAST_CALL_STATUS=$status
  LAST_CALL_MSG=$msg
  if [[ $status == ok ]]; then
    log_debug "$id: ok http=${http_ms:-?}ms wall=$((t1 - t0))ms bytes=$bytes"
  else
    log_warn "$id: $status${http_status:+ (HTTP $http_status)} after $((t1 - t0))ms: ${msg:0:300}"
  fi
  rm -f "$errf"
  [[ $status == ok ]]
}

# Keeps only the metric families matching INCLUDE_RE (minus EXCLUDE_RE) and
# stores them gzipped as OUT.gz (histograms compress ~30x).
filter_prom() {
  local include=$1 in=$2 out=$3 exclude=${4:-}
  if [[ -n $exclude ]]; then
    { grep -E "$include" "$in" | grep -vE "$exclude" || true; } | gzip -c >"$out.gz"
  else
    { grep -E "$include" "$in" || true; } | gzip -c >"$out.gz"
  fi
  if $KEEP_RAW_METRICS; then gzip -f "$in"; else rm -f "$in"; fi
}

define JQ_REDACT <<'JQ'
def redact_env: if (.env | type) == "array" then .env |= map(if has("value") then .value = "<redacted>" else . end) else . end;
def redact_podspec: (.containers[]? |= redact_env) | (.initContainers[]? |= redact_env) | (.ephemeralContainers[]? |= redact_env);
.items[]? |= (
  del(.metadata.managedFields)
  | del(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])
  | if (.spec.containers | type) == "array" then .spec |= redact_podspec
    elif (.spec.template.spec | type) == "object" then .spec.template.spec |= redact_podspec
    else . end
  | del(.status.images))
JQ

redact_json() {
  local f=$1
  $REDACT || return 0
  if jq "$JQ_REDACT" "$f" >"$f.tmp"; then mv -f "$f.tmp" "$f"; else rm -f "$f.tmp"; fi
}

# ------------------------------------------------------------- collection --
save_failure_body() {
  # A failing /livez or /readyz returns its check list in the error message.
  printf '%s\n' "$LAST_CALL_MSG" >"$1"
}

collect_cluster() {
  step "[1/8] Connectivity and API server health"
  if ! api_call cluster version /version "$RAW/cluster/version.json" get --raw /version; then
    die 2 "cannot reach the Kubernetes API server ($LAST_CALL_STATUS): ${LAST_CALL_MSG:0:300}"
  fi
  api_call cluster livez '/livez?verbose' "$RAW/cluster/livez.txt" get --raw '/livez?verbose' ||
    { [[ $DRY_RUN == client ]] || save_failure_body "$RAW/cluster/livez.txt"; }
  api_call cluster readyz '/readyz?verbose' "$RAW/cluster/readyz.txt" get --raw '/readyz?verbose' ||
    { [[ $DRY_RUN == client ]] || save_failure_body "$RAW/cluster/readyz.txt"; }

  step "[2/8] Cluster inventory: nodes and namespaces"
  api_call cluster list:nodes nodes "$RAW/cluster/nodes.json" get nodes -o json &&
    { [[ $DRY_RUN == client ]] || redact_json "$RAW/cluster/nodes.json"; }
  if ((${#NAMESPACES[@]} == 0)); then
    api_call cluster list:namespaces namespaces "$RAW/cluster/namespaces.json" get namespaces -o json
  else
    local ns parts=()
    for ns in "${NAMESPACES[@]}"; do
      api_call cluster "get:namespace:$ns" "namespace/$ns" "$RAW/cluster/namespace.$ns.json" get namespace "$ns" -o json &&
        parts+=("$RAW/cluster/namespace.$ns.json")
    done
    if [[ $DRY_RUN != client ]] && ((${#parts[@]})); then
      jq -s '{apiVersion: "v1", kind: "List", items: .}' "${parts[@]}" >"$RAW/cluster/namespaces.json"
      rm -f "${parts[@]}"
    fi
  fi
}

scrape_apiserver_metrics() {
  local which=$1
  local full="$RAW/metrics/apiserver-$which.full.prom" out="$RAW/metrics/apiserver-$which.prom"
  if $SKIP_APISERVER_METRICS; then
    log_info "skipped (--skip-apiserver-metrics)"
    return 0
  fi
  if [[ $which == start ]]; then SCRAPE_START_MS=$(now_ms); else SCRAPE_END_MS=$(now_ms); fi
  if api_call apiserver "metrics:apiserver:$which" /metrics "$full" get --raw /metrics; then
    [[ $DRY_RUN == client ]] || filter_prom "$APISERVER_FAMILIES" "$full" "$out"
  fi
}

probe_endpoints() {
  local first_ns=${NAMESPACES[0]:-}
  local pods="/api/v1/pods?limit=500" events="/api/v1/events?limit=500" one_ns="/api/v1/namespaces/kube-system"
  if [[ -n $first_ns ]]; then
    pods="/api/v1/namespaces/$first_ns/pods?limit=500"
    events="/api/v1/namespaces/$first_ns/events?limit=500"
    one_ns="/api/v1/namespaces/$first_ns"
  fi
  printf '%s\n' \
    "livez=/livez" \
    "readyz=/readyz" \
    "version=/version" \
    "discovery=/apis" \
    "get-namespace=$one_ns" \
    "list-namespaces=/api/v1/namespaces?limit=500" \
    "list-nodes=/api/v1/nodes?limit=500" \
    "list-pods=$pods" \
    "list-events=$events" \
    "list-leases=/apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases?limit=500" \
    ${PROBE_ENDPOINTS_EXTRA[@]+"${PROBE_ENDPOINTS_EXTRA[@]}"}
}

run_api_probes() {
  step "[4/8] Client-side API latency probes ($PROBE_SAMPLES samples per endpoint, round-robin)"
  if ((PROBE_SAMPLES == 0)); then
    log_info "skipped (--probe-samples 0)"
    return 0
  fi
  local -a specs
  mapfile -t specs < <(probe_endpoints)
  local i spec
  if [[ $DRY_RUN == client ]]; then
    for spec in "${specs[@]}"; do
      api_call probe "probe:${spec%%=*}:1..$PROBE_SAMPLES" "${spec#*=}" - get --raw "${spec#*=}"
    done
    PLAN_COUNT=$((PLAN_COUNT + ${#specs[@]} * (PROBE_SAMPLES - 1)))
  else
    for ((i = 1; i <= PROBE_SAMPLES; i++)); do
      for spec in "${specs[@]}"; do
        api_call probe "probe:${spec%%=*}:$i" "${spec#*=}" - get --raw "${spec#*=}" || true
      done
    done
  fi
  $WRITE_PROBE && run_write_probe
}

run_write_probe() {
  local i name manifest ns=$WRITE_PROBE_NS
  local n=$PROBE_SAMPLES
  [[ $DRY_RUN == client ]] && n=1
  for ((i = 1; i <= n; i++)); do
    name="k8s-perf-probe-${RUN_ID,,}-$i"
    manifest="$TMP_DIR/probe-cm-$i.json"
    if [[ $DRY_RUN != client ]]; then
      jq -n --arg name "$name" --arg ns "$ns" --arg run "$RUN_ID" \
        '{apiVersion: "v1", kind: "ConfigMap",
          metadata: {name: $name, namespace: $ns,
                     labels: {"app.kubernetes.io/managed-by": "k8s-perf-collector", "k8s-perf/run": $run}},
          data: {probe: "1"}}' >"$manifest"
    fi
    api_call probe "probe:cm-create:$i" "POST configmaps ($ns)" - create --validate=false -f "$manifest" -o name || continue
    api_call probe "probe:cm-get:$i" "GET configmap ($ns)" - get configmap "$name" -n "$ns" -o name || true
    api_call probe "probe:cm-patch:$i" "PATCH configmap ($ns)" - patch configmap "$name" -n "$ns" --type=merge -p '{"data":{"probe":"2"}}' || true
    api_call probe "probe:cm-delete:$i" "DELETE configmap ($ns)" - delete configmap "$name" -n "$ns" --wait=false || true
  done
  [[ $DRY_RUN == client ]] && PLAN_COUNT=$((PLAN_COUNT + 4 * (PROBE_SAMPLES - 1)))
}

# shellcheck disable=SC2329 # called from the EXIT trap via cleanup()
cleanup_write_probe() {
  $WRITE_PROBE || return 0
  [[ -n $RUN_ID && ${#KUBECTL[@]} -gt 0 && -z $DRY_RUN ]] || return 0
  "${KUBECTL[@]}" delete configmap -n "$WRITE_PROBE_NS" \
    -l "app.kubernetes.io/managed-by=k8s-perf-collector,k8s-perf/run=$RUN_ID" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

collect_list() {
  local name=$1 res=$2 out="$RAW/objects/$1.json"
  if ((${#NAMESPACES[@]} == 0)); then
    api_call objects "list:$name" "$res" "$out" get "$res" --all-namespaces -o json
  else
    local ns parts=()
    for ns in "${NAMESPACES[@]}"; do
      api_call objects "list:$name:$ns" "$res -n $ns" "$out.$ns" get "$res" -n "$ns" -o json &&
        parts+=("$out.$ns")
    done
    [[ $DRY_RUN == client ]] && return 0
    if ((${#parts[@]})); then
      jq -s '{apiVersion: "v1", kind: "List", items: [.[].items[]]}' "${parts[@]}" >"$out"
      rm -f "${parts[@]}"
    fi
  fi
  [[ $DRY_RUN == client ]] && return 0
  [[ -s $out ]] && redact_json "$out"
  return 0
}

collect_objects() {
  step "[5/8] Namespaced objects: pods, events, workloads, PVCs, quotas, services, HPAs"
  local entry
  for entry in "${OBJECT_LISTS[@]}"; do
    collect_list "${entry%%:*}" "${entry#*:}"
  done
}

node_targets() {
  if ((${#NAMESPACES[@]})) || [[ ! -s $RAW/cluster/nodes.json ]]; then
    # Only the nodes that run pods in scope (also the fallback when listing
    # nodes is forbidden).
    jq -r '[.items[].spec.nodeName // empty] | unique[]' "$RAW/objects/pods.json" 2>/dev/null
  else
    jq -r '.items[].metadata.name' "$RAW/cluster/nodes.json"
  fi
}

scrape_node() {
  local node=$1 dir="$RAW/nodes/$1" base="/api/v1/nodes/$1/proxy"
  [[ $DRY_RUN == client ]] || mkdir -p "$dir"
  api_call node "node:$node:summary" "$base/stats/summary" "$dir/summary.json" get --raw "$base/stats/summary"
  if api_call node "node:$node:cadvisor" "$base/metrics/cadvisor" "$dir/cadvisor.full.prom" get --raw "$base/metrics/cadvisor"; then
    [[ $DRY_RUN == client ]] || filter_prom "$CADVISOR_FAMILIES" "$dir/cadvisor.full.prom" "$dir/cadvisor.prom" "$CADVISOR_EXCLUDE"
  fi
  if api_call node "node:$node:probes" "$base/metrics/probes" "$dir/probes.full.prom" get --raw "$base/metrics/probes"; then
    [[ $DRY_RUN == client ]] || filter_prom "$PROBER_FAMILIES" "$dir/probes.full.prom" "$dir/probes.prom"
  fi
  if api_call node "node:$node:kubelet" "$base/metrics" "$dir/kubelet.full.prom" get --raw "$base/metrics"; then
    [[ $DRY_RUN == client ]] || filter_prom "$KUBELET_FAMILIES" "$dir/kubelet.full.prom" "$dir/kubelet.prom"
  fi
  return 0
}

collect_node_stats() {
  step "[6/8] Node and container level: kubelet Summary API, cAdvisor, prober and kubelet metrics (via node proxy, $PARALLEL in parallel)"
  if $SKIP_NODE_STATS; then
    log_info "skipped (--skip-node-stats)"
    return 0
  fi
  local -a nodes=()
  if [[ $DRY_RUN == client ]]; then
    nodes=("<node>")
  else
    mapfile -t nodes < <(node_targets)
  fi
  if ((${#nodes[@]} == 0)); then
    log_warn "no nodes to scrape"
    return 0
  fi
  if ((MAX_NODES > 0 && ${#nodes[@]} > MAX_NODES)); then
    log_warn "scraping ${MAX_NODES} of ${#nodes[@]} nodes (--max-nodes)"
    nodes=("${nodes[@]:0:MAX_NODES}")
  fi
  local node
  for node in "${nodes[@]}"; do
    if [[ $DRY_RUN == client ]]; then
      scrape_node "$node"
      printf '    %-34s (repeated for every node in scope)\n' ""
      continue
    fi
    scrape_node "$node" &
    while (($(jobs -rp | wc -l) >= PARALLEL)); do
      if $HAVE_WAIT_N; then wait -n; else sleep 0.2; fi
    done
  done
  wait
}

collect_metrics_server() {
  step "[7/8] metrics.k8s.io (metrics-server) - optional fallback for container usage"
  local out="$RAW/metrics/metrics-server-pods.json"
  if ((${#NAMESPACES[@]} == 0)); then
    api_call metrics metrics:metrics-server:pods /apis/metrics.k8s.io/v1beta1/pods "$out" \
      get --raw /apis/metrics.k8s.io/v1beta1/pods ||
      log_info "metrics-server not available ($LAST_CALL_STATUS); the kubelet Summary API is the usage source"
  else
    local ns parts=()
    for ns in "${NAMESPACES[@]}"; do
      api_call metrics "metrics:metrics-server:pods:$ns" "/apis/metrics.k8s.io/v1beta1/namespaces/$ns/pods" "$out.$ns" \
        get --raw "/apis/metrics.k8s.io/v1beta1/namespaces/$ns/pods" && parts+=("$out.$ns")
    done
    if [[ $DRY_RUN != client ]] && ((${#parts[@]})); then
      jq -s '{kind: "PodMetricsList", items: [.[].items[]]}' "${parts[@]}" >"$out"
      rm -f "${parts[@]}"
    fi
  fi
}

finish_window() {
  step "[8/8] API server metrics, scrape 2 of 2 (closes the ${WINDOW}s observation window)"
  if ((WINDOW > 0)) && ! $SKIP_APISERVER_METRICS; then
    if [[ $DRY_RUN == client ]]; then
      printf '    %-34s %s\n' "(wait)" "sleep until ${WINDOW}s have passed since scrape 1"
    else
      local remaining=$((WINDOW - ($(now_ms) - SCRAPE_START_MS) / 1000))
      if ((remaining > 0)); then
        log_info "waiting ${remaining}s for the ${WINDOW}s observation window to close"
        sleep "$remaining"
      fi
    fi
    scrape_apiserver_metrics end
  else
    log_info "window disabled; API server counters will be reported cumulative since its start"
  fi
}

write_run_meta() {
  local finished_epoch window_actual=0
  finished_epoch=$(date +%s)
  if ((SCRAPE_END_MS > 0 && SCRAPE_START_MS > 0)); then
    window_actual=$(((SCRAPE_END_MS - SCRAPE_START_MS) / 1000))
  fi
  local kubectl_version
  kubectl_version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "unknown"')
  jq -n \
    --arg version "$VERSION" --arg run_id "$RUN_ID" --arg context "$CTX_NAME" \
    --arg started "$STARTED_AT" --arg finished "$(ts_utc)" \
    --argjson started_epoch "$STARTED_EPOCH" --argjson finished_epoch "$finished_epoch" \
    --arg kubectl_version "$kubectl_version" --arg clock "$CLOCK" \
    --argjson namespaces "$(json_array ${NAMESPACES[@]+"${NAMESPACES[@]}"})" \
    --argjson window "$WINDOW" --argjson window_actual "$window_actual" \
    --argjson probe_samples "$PROBE_SAMPLES" --argjson timeout "$REQUEST_TIMEOUT" \
    --argjson parallel "$PARALLEL" --argjson max_nodes "$MAX_NODES" \
    --argjson skip_node_stats "$SKIP_NODE_STATS" --argjson skip_apiserver_metrics "$SKIP_APISERVER_METRICS" \
    --argjson write_probe "$WRITE_PROBE" --argjson redacted "$REDACT" \
    --argjson thresholds "$(thresholds_json)" \
    '{tool: "k8s-perf-collector", version: $version, run_id: $run_id, context: $context,
      started_at: $started, finished_at: $finished, started_epoch: $started_epoch,
      finished_epoch: $finished_epoch, duration_s: ($finished_epoch - $started_epoch),
      kubectl_version: $kubectl_version, clock: $clock,
      scope: {all_namespaces: ($namespaces | length == 0), namespaces: $namespaces},
      window_s: $window, window_actual_s: $window_actual, probe_samples: $probe_samples,
      request_timeout_s: $timeout, parallel: $parallel, max_nodes: $max_nodes,
      skip_node_stats: $skip_node_stats, skip_apiserver_metrics: $skip_apiserver_metrics,
      write_probe: $write_probe, redacted: $redacted, thresholds: $thresholds}' >"$OUT_DIR/meta/run.json"
}

collect() {
  mkdir -p "$OUT_DIR"/{meta,csv,analysis} "$RAW"/{cluster,objects,metrics,nodes} ||
    die 1 "cannot create output directory $OUT_DIR"
  LOG_FILE="$OUT_DIR/collector.log"
  CALLS_TSV="$OUT_DIR/meta/calls.tsv"
  printf 'ts\tphase\tid\ttarget\tstatus\texit_code\twall_ms\thttp_ms\thttp_requests\thttp_status\tbytes\tnotes\tmessage\n' >"$CALLS_TSV"
  log_info "k8s-perf-collector $VERSION: context=$CTX_NAME scope=${NAMESPACES[*]:-all-namespaces} window=${WINDOW}s output=$OUT_DIR"

  collect_cluster
  step "[3/8] API server metrics, scrape 1 of 2 (opens the ${WINDOW}s observation window)"
  scrape_apiserver_metrics start
  run_api_probes
  collect_objects
  collect_node_stats
  collect_metrics_server
  finish_window
  write_run_meta
  log_info "collection finished: $(($(wc -l <"$CALLS_TSV") - 1)) API calls in $(($(date +%s) - STARTED_EPOCH))s"
}

# --------------------------------------------------------------- dry runs --
dry_run_plan() {
  printf 'k8s-perf-collector %s - DRY RUN (%s): ' "$VERSION" "$DRY_RUN"
  if [[ $DRY_RUN == client ]]; then
    printf 'no request is sent to the cluster and nothing is written.\n'
  else
    printf 'read-only connectivity/RBAC preflight; nothing is collected or written.\n'
  fi

  printf '\nPrerequisites\n'
  local kv jqv tv
  kv=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || true)
  jqv=$(jq --version 2>/dev/null || true)
  printf '  %-12s %-28s %s\n' bash "$BASH_VERSION" ok
  printf '  %-12s %-28s %s\n' kubectl "${kv:-not found}" "$([[ -n $kv ]] && echo ok || echo MISSING)"
  printf '  %-12s %-28s %s\n' jq "${jqv:-not found}" "$([[ -n $jqv ]] && echo ok || echo MISSING)"
  tv=${TIMEOUT_BIN:-not found}
  printf '  %-12s %-28s %s\n' timeout "$tv" "$([[ -n $TIMEOUT_BIN ]] && echo ok || echo 'optional')"
  printf '  %-12s %-28s %s\n' clock "$CLOCK" "$([[ $CLOCK == seconds ]] && echo 'low resolution' || echo 'ms resolution')"

  printf '\nConfiguration\n'
  printf '  %-26s %s\n' "kube context" "$CTX_NAME$([[ $DRY_RUN == client ]] && echo " (read from kubeconfig, not contacted)")"
  printf '  %-26s %s\n' "scope" "${NAMESPACES[*]:-all namespaces}"
  printf '  %-26s %s\n' "output directory" "$OUT_DIR"
  printf '  %-26s %s\n' "observation window" "${WINDOW}s"
  printf '  %-26s %s\n' "latency probe samples" "$PROBE_SAMPLES per endpoint"
  printf '  %-26s %s\n' "request timeout" "${REQUEST_TIMEOUT}s per request"
  printf '  %-26s %s\n' "kubelet scraping" "$($SKIP_NODE_STATS && echo disabled || echo "enabled, $PARALLEL nodes in parallel$( ((MAX_NODES > 0)) && echo ", at most $MAX_NODES nodes")")"
  printf '  %-26s %s\n' "write probe" "$($WRITE_PROBE && echo "enabled (namespace $WRITE_PROBE_NS)" || echo 'disabled (read-only run)')"
  printf '  %-26s %s\n' "redaction" "$($REDACT && echo 'env values, managedFields, last-applied annotations removed' || echo disabled)"
  printf '  %-26s %s\n' "thresholds" "$(thresholds_json)"

  printf '\nCollection plan (each line is one kubectl invocation, timed and classified)\n'
  local saved=$DRY_RUN
  DRY_RUN=client
  collect_cluster
  step "[3/8] API server metrics, scrape 1 of 2 (opens the ${WINDOW}s observation window)"
  scrape_apiserver_metrics start
  run_api_probes
  collect_objects
  collect_node_stats
  collect_metrics_server
  finish_window
  DRY_RUN=$saved

  printf '\nAnalysis outputs (written to %s)\n' "$OUT_DIR"
  printf '  %s\n' \
    "report.md                    human-readable report: verdict, API, nodes, namespaces, containers, events" \
    "summary.json                 everything above as structured JSON" \
    "csv/failures.csv             every finding: severity, category, object, reason, message" \
    "csv/containers.csv           per container: state, restarts, exit codes, CPU/memory vs requests/limits, throttling, OOM, probes" \
    "csv/namespaces.csv           per namespace: pod phases, usage vs requests/limits, restarts, warning events, quota" \
    "csv/nodes.csv                per node: conditions, allocatable, requests, usage, disk, PIDs, kubelet health" \
    "csv/api_client_latency.csv   per probed endpoint: samples, timeouts, errors, p50/p90/p99" \
    "csv/apiserver_latency.csv    per verb/resource: request count and p50/p90/p99 vs upstream SLOs" \
    "csv/apiserver_errors.csv     5xx/429 responses, request terminations, APF rejections" \
    "csv/events.csv               all events aggregated per object/reason with category" \
    "csv/collector_calls.csv      every API call this run made, with timings and outcome" \
    "collector.log                run log including every timeout and error" \
    "raw/                         raw API responses (filtered Prometheus scrapes, object lists)"
  printf '\nPlanned kubectl invocations: %d for a single node (+4 per additional node)\n' "$PLAN_COUNT"
}

preflight_server() {
  printf '\nServer preflight\n'
  local t0 t1 ver
  t0=$(now_ms)
  if ! ver=$("${KUBECTL[@]}" get --raw /version 2>&1); then
    printf '  %-34s NO - %s\n' "API server reachable" "$(printf '%s' "$ver" | head -c 300 | tr '\n' ' ')"
    return 2
  fi
  t1=$(now_ms)
  printf '  %-34s yes (%s, %dms incl. kubectl start-up)\n' "API server reachable" \
    "$(printf '%s' "$ver" | jq -r '.gitVersion // "?"' 2>/dev/null)" "$((t1 - t0))"
  if "${KUBECTL[@]}" get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null 2>&1; then
    printf '  %-34s %s\n' "metrics-server (metrics.k8s.io)" "installed"
  else
    printf '  %-34s %s\n' "metrics-server (metrics.k8s.io)" "not installed (fine - kubelet Summary API is used)"
  fi

  count_items() {
    "${KUBECTL[@]}" get --raw "$1" 2>/dev/null |
      jq -r '((.metadata.remainingItemCount // 0) + (.items | length)) | tostring' 2>/dev/null || echo "?"
  }
  local nodes namespaces pods=0 events=0 ns c
  nodes=$(count_items '/api/v1/nodes?limit=1')
  namespaces=$(count_items '/api/v1/namespaces?limit=1')
  if ((${#NAMESPACES[@]} == 0)); then
    pods=$(count_items '/api/v1/pods?limit=1')
    events=$(count_items '/api/v1/events?limit=1')
  else
    for ns in "${NAMESPACES[@]}"; do
      c=$(count_items "/api/v1/namespaces/$ns/pods?limit=1")
      [[ $c =~ ^[0-9]+$ ]] && pods=$((pods + c))
      c=$(count_items "/api/v1/namespaces/$ns/events?limit=1")
      [[ $c =~ ^[0-9]+$ ]] && events=$((events + c))
    done
  fi
  printf '  %-34s nodes=%s namespaces=%s pods=%s events=%s\n' "cluster size (in scope)" "$nodes" "$namespaces" "$pods" "$events"

  printf '\n  RBAC (SelfSubjectAccessReview, as the identity the collector will use)\n'
  printf '  %-6s %-40s %-12s %-8s %s\n' VERB RESOURCE SCOPE ALLOWED PURPOSE
  local spec verb res scope purpose answer denied=0
  local -a checks=("${RBAC_CHECKS[@]}")
  if $WRITE_PROBE; then
    checks+=("create|configmaps|probe|--write-probe" "patch|configmaps|probe|--write-probe" "delete|configmaps|probe|--write-probe")
  fi
  for spec in "${checks[@]}"; do
    IFS='|' read -r verb res scope purpose <<<"$spec"
    answer=$(can_i "$verb" "$res" "$scope")
    [[ $answer == yes ]] || denied=$((denied + 1))
    printf '  %-6s %-40s %-12s %-8s %s\n' "$verb" "$res" "$scope" "$answer" "$purpose"
  done

  local n_nodes=${nodes//[!0-9]/}
  n_nodes=${n_nodes:-1}
  ((MAX_NODES > 0 && n_nodes > MAX_NODES)) && n_nodes=$MAX_NODES
  $SKIP_NODE_STATS && n_nodes=0
  local nscount=$((${#NAMESPACES[@]} == 0 ? 1 : ${#NAMESPACES[@]}))
  local probe_calls=$((PROBE_SAMPLES * (10 + ${#PROBE_ENDPOINTS_EXTRA[@]})))
  $WRITE_PROBE && probe_calls=$((probe_calls + 4 * PROBE_SAMPLES))
  local est=$((3 + 1 + nscount + 2 + probe_calls + ${#OBJECT_LISTS[@]} * nscount + 4 * n_nodes + nscount))
  printf '\n  Estimated kubectl invocations for a real run: ~%d (minimum duration ~%ds)\n' "$est" "$WINDOW"
  if ((denied > 0)); then
    printf '  %d permission(s) missing: the run still works, the matching data is reported as unavailable.\n' "$denied"
    printf '  See k8s-perf/manifests/rbac.yaml for a read-only ClusterRole that grants all of them.\n'
  fi
  printf '\nPreflight complete; nothing was collected.\n'
}

# can_i VERB RESOURCE SCOPE -> yes|no|partial
#   Sends a SelfSubjectAccessReview with explicit group/resource attributes
#   (kubectl auth can-i needs discovery and answers "no" for API groups that
#   are not currently served, e.g. metrics.k8s.io without metrics-server).
can_i() {
  local verb=$1 res=$2 scope=$3
  if [[ $scope == namespaced && ${#NAMESPACES[@]} -gt 0 ]]; then
    local ns yes=0
    for ns in "${NAMESPACES[@]}"; do
      [[ $(ssar "$verb" "$res" "$ns") == yes ]] && yes=$((yes + 1))
    done
    if ((yes == ${#NAMESPACES[@]})); then echo yes; elif ((yes > 0)); then echo partial; else echo no; fi
    return
  fi
  local ns=""
  [[ $scope == probe ]] && ns=$WRITE_PROBE_NS
  ssar "$verb" "$res" "$ns"
}

ssar() {
  local verb=$1 res=$2 ns=$3 attrs resource=$2 sub="" group=""
  if [[ $res == /* ]]; then
    attrs=$(jq -nc --arg v "$verb" --arg p "$res" '{nonResourceAttributes: {verb: $v, path: $p}}')
  else
    if [[ $resource == */* ]]; then sub=${resource#*/}; resource=${resource%%/*}; fi
    if [[ $resource == *.* ]]; then group=${resource#*.}; resource=${resource%%.*}; fi
    attrs=$(jq -nc --arg v "$verb" --arg r "$resource" --arg s "$sub" --arg g "$group" --arg n "$ns" \
      '{resourceAttributes: {verb: $v, resource: $r, subresource: $s, group: $g, namespace: $n}}')
  fi
  local out
  out=$(jq -nc --argjson spec "$attrs" '{apiVersion: "authorization.k8s.io/v1", kind: "SelfSubjectAccessReview", spec: $spec}' |
    "${KUBECTL[@]}" create --validate=false -f - -o jsonpath='{.status.allowed}' 2>/dev/null)
  [[ $out == true ]] && echo yes || echo no
}

# ------------------------------------------------------------------ analysis --
define JQ_LIB <<'JQ'
def rnd($d): if . == null then null else pow(10; $d) as $m | ((. * $m + 0.5) | floor) / $m end;
def ms: if . == null then null else . * 1000 | rnd(1) end;
def mib: if . == null then null else . / 1048576 | rnd(1) end;
def pct($a; $b): if $a == null or $b == null or $b == 0 then null else ($a * 100 / $b | rnd(1)) end;
def one_line: if . == null then "" else tostring | gsub("[\\r\\n\\t]+"; " ") | gsub(" {2,}"; " ") | ltrimstr(" ") end;
def trunc($n): if length > $n then .[0:$n] + "..." else . end;
def epoch: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) end;
def minutes_since($now): epoch as $t | if $t == null then null else (($now - $t) / 60 | rnd(1)) end;
def cpu_m:
  if . == null then null else tostring as $s
  | try (if ($s | endswith("m")) then ($s | rtrimstr("m") | tonumber)
         elif ($s | endswith("u")) then ($s | rtrimstr("u") | tonumber / 1000)
         elif ($s | endswith("n")) then ($s | rtrimstr("n") | tonumber / 1000000)
         else ($s | tonumber * 1000) end) catch null end;
def bytes:
  if . == null then null else
    ((tostring | capture("^(?<n>[0-9.]+(?:[eE][+-]?[0-9]+)?)(?<u>[A-Za-z]*)$")) // null) as $c
    | if $c == null then null else
        ($c.n | tonumber) * ({"": 1, "m": 0.001, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15, "E": 1e18,
          "Ki": 1024, "Mi": 1048576, "Gi": 1073741824, "Ti": 1099511627776, "Pi": 1125899906842624,
          "Ei": 1152921504606846976}[$c.u] // 1) end end;
def qty($res): if ($res | test("cpu")) then cpu_m else bytes end;
def prom_value: if . == "+Inf" then infinite elif . == "-Inf" then -infinite elif . == "NaN" then 0 else (try tonumber catch 0) end;
def parse_prom:
  ((capture("^(?<n>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\\{(?<l>.*)\\})?[ \\t]+(?<v>[^ \\t]+)")) // null)
  | select(. != null)
  | {n, k: (.n + "{" + (.l // "") + "}"),
     l: ([(.l // "") | scan("([a-zA-Z_][a-zA-Z0-9_]*)=\"((?:[^\"\\\\]|\\\\.)*)\"") | {key: .[0], value: .[1]}] | from_entries),
     v: (.v | prom_value)};
def le_num: if . == "+Inf" then infinite else (try tonumber catch infinite) end;
# Prometheus-style histogram_quantile over cumulative buckets [{le, c}].
def hq($q; $b):
  ([$b[] | select(.le == infinite) | .c] | .[0] // ($b | last | .c) // 0) as $total
  | if $total <= 0 then null else
      ($q * $total) as $rank
      | ([range(0; $b | length) | select($b[.].c >= $rank)] | .[0] // ($b | length - 1)) as $i
      | if $b[$i].le == infinite then (if $i > 0 then $b[$i - 1].le else null end)
        else (if $i == 0 then 0 else $b[$i - 1].le end) as $lo
          | (if $i == 0 then 0 else $b[$i - 1].c end) as $clo
          | if $b[$i].c == $clo then $b[$i].le
            else $lo + ($b[$i].le - $lo) * ($rank - $clo) / ($b[$i].c - $clo) end
        end
    end;
def hgroup(f): group_by(f) | map({key: (.[0] | f),
  buckets: (group_by(.l.le) | map({le: (.[0].l.le | le_num), c: (map(.v) | add)}) | sort_by(.le))});
def hsum: {count: ([.buckets[] | select(.le == infinite) | .c] | .[0] // 0),
  p50_ms: (hq(0.5; .buckets) | ms), p90_ms: (hq(0.9; .buckets) | ms), p99_ms: (hq(0.99; .buckets) | ms)};
def nearest($q): sort | if length == 0 then null else .[(((length * $q) | ceil) - 1) as $i | if $i < 0 then 0 else $i end] end;
def csvrow: map(if . == null then "" elif type == "boolean" then tostring elif type == "object" or type == "array" then tojson else . end) | @csv;
def to_csv($cols): ($cols | csvrow), (.[] | . as $r | [$cols[] | $r[.]] | csvrow);
JQ

define JQ_CALLS <<'JQ'
split("\n") | .[1:] | map(select(length > 0) | split("\t") | {
  ts: .[0], phase: .[1], id: .[2], target: .[3], status: .[4],
  exit_code: (.[5] | tonumber? // null), wall_ms: (.[6] | tonumber? // null),
  http_ms: (.[7] | tonumber? // null), http_requests: (.[8] | tonumber? // 0),
  http_status: (.[9] // ""), bytes: (.[10] | tonumber? // 0), notes: (.[11] // ""), message: (.[12] // "")})
JQ

define JQ_APISERVER <<'JQ'
def ser($s; $n): [$s[] | select(.n == $n)];
def total: (map(.v) | add) // 0;
def res_name: if (.l.resource // "") == "" then (.l.subresource // "")
  else .l.resource + (if (.l.subresource // "") != "" then "/" + .l.subresource else "" end) end;
def longrunning: (.l.verb // "") | IN("WATCH", "WATCHLIST", "CONNECT");
# etcd metrics label the object kind "resource"+"group" (>= 1.30) or "type" (older).
def etcd_res: if (.l.resource // "") != "" then .l.resource + (if (.l.group // "") != "" then "." + .l.group else "" end) else (.l.type // "") end;
$start[0] as $s0 | $end[0] as $s1
| (if ($s1 | length) > 0 then $s1 else $s0 end) as $last
| ((ser($s0; "process_start_time_seconds") | .[0].v) // null) as $st0
| ((ser($last; "process_start_time_seconds") | .[0].v) // null) as $st1
| (($s0 | length) > 0 and ($s1 | length) > 0) as $both
| ($both and $window > 0 and $st0 == $st1) as $windowed
| (if $windowed then
     ([$s0[] | {key: .k, value: .v}] | from_entries) as $base
     | [$last[] | . as $e | ($base[$e.k]) as $p
        | .v = (if $p == null then $e.v elif $e.v >= $p then $e.v - $p else $e.v end)]
   else $last end) as $cum
| (if $windowed then $window elif $st1 != null then ($now - $st1) else null end) as $secs
| def per_s: if $secs == null or $secs <= 0 then null else (. / $secs | rnd(3)) end;
  ser($cum; "apiserver_request_total") as $req
| ($req | total) as $req_total
| ([$req | group_by(.l.code)[] | {code: .[0].l.code, count: total}] | map(select(.count > 0))) as $by_code
| def codes(f): [$by_code[] | select(.code | f) | .count] | add // 0;
  [ser($cum; "apiserver_request_duration_seconds_bucket")[] | select(longrunning | not)] as $dur
| {
    available: (($last | length) > 0),
    mode: (if $windowed then "window" elif ($last | length) > 0 then "cumulative" else "unavailable" end),
    window_s: (if $windowed then $window else null end),
    seconds_covered: (if $secs == null then null else ($secs | floor) end),
    instance_changed: ($both and $st0 != $st1),
    version: ((ser($last; "kubernetes_build_info") | .[0].l.git_version) // null),
    requests: {
      total: $req_total, per_second: ($req_total | per_s), by_code: $by_code,
      code_5xx: codes(startswith("5")), code_429: codes(. == "429"),
      code_401_403: codes(. == "401" or . == "403"), code_404: codes(. == "404"), code_409: codes(. == "409"),
      error_ratio_pct: pct(codes(startswith("5")); $req_total)
    },
    error_series: ([$req[] | select(.v > 0 and ((.l.code | startswith("5")) or .l.code == "429"))
                    | {verb: .l.verb, resource: res_name, code: .l.code, count: .v}] | sort_by(-.count) | .[0:25]),
    latency_by_class: ($dur | hgroup({class: (if .l.verb | IN("GET", "LIST") then "read-only" else "mutating" end)})
                       | map(.key + hsum) | map(select(.count > 0))),
    latency: ($dur | hgroup({verb: .l.verb, resource: res_name, scope: (.l.scope // "")})
              | map(.key + hsum) | map(select(.count > 0))
              | map(.slo_ms = (if .verb == "LIST" then (if .scope == "cluster" then 30000 elif .scope == "namespace" then 5000 else 1000 end) else 1000 end)
                    | .slo_breach = (.p99_ms != null and .p99_ms > .slo_ms))
              | sort_by(-(.p99_ms // 0))),
    terminations: ([ser($cum; "apiserver_request_terminations_total")[] | select(.v > 0)
                    | {verb: .l.verb, resource: res_name, code: .l.code, count: .v}] | sort_by(-.count)),
    aborts: ([ser($cum; "apiserver_request_aborts_total")[] | select(.v > 0)
              | {verb: .l.verb, resource: res_name, count: .v}] | sort_by(-.count)),
    apf: {
      rejected: ([ser($cum; "apiserver_flowcontrol_rejected_requests_total")[] | select(.v > 0)
                  | {priority_level: .l.priority_level, flow_schema: .l.flow_schema, reason: .l.reason, count: .v}] | sort_by(-.count)),
      wait: (ser($cum; "apiserver_flowcontrol_request_wait_duration_seconds_bucket") | hgroup({priority_level: .l.priority_level})
             | map(.key + hsum) | map(select(.count > 0)) | sort_by(-(.p99_ms // 0))),
      in_queue: ([ser($last; "apiserver_flowcontrol_current_inqueue_requests")[] | select(.v > 0)
                  | {priority_level: .l.priority_level, flow_schema: .l.flow_schema, requests: .v}])
    },
    inflight: ([ser($last; "apiserver_current_inflight_requests")[] | {key: .l.request_kind, value: .v}] | from_entries),
    long_running: (ser($last; "apiserver_longrunning_requests") | total),
    etcd: {
      by_operation: (ser($cum; "etcd_request_duration_seconds_bucket") | hgroup({operation: .l.operation})
                     | map(.key + hsum) | map(select(.count > 0)) | sort_by(-(.p99_ms // 0))),
      slowest: (ser($cum; "etcd_request_duration_seconds_bucket") | hgroup({operation: .l.operation, resource: etcd_res})
                | map(.key + hsum) | map(select(.count > 0)) | sort_by(-(.p99_ms // 0)) | .[0:10]),
      errors: ([ser($cum; "etcd_request_errors_total")[] | select(.v > 0) | {operation: .l.operation, resource: etcd_res, count: .v}])
    },
    webhooks: {
      latency: (ser($cum; "apiserver_admission_webhook_admission_duration_seconds_bucket")
                | hgroup({name: .l.name, type: .l.type, operation: .l.operation})
                | map(.key + hsum) | map(select(.count > 0)) | sort_by(-(.p99_ms // 0))),
      rejections: ([ser($cum; "apiserver_admission_webhook_rejection_count")[] | select(.v > 0)
                    | {name: .l.name, type: .l.type, operation: .l.operation, error_type: .l.error_type, code: .l.rejection_code, count: .v}]),
      fail_open: ([ser($cum; "apiserver_admission_webhook_fail_open_count")[] | select(.v > 0) | {name: .l.name, type: .l.type, count: .v}])
    },
    objects: ((ser($last; "apiserver_resource_objects") + ser($last; "apiserver_storage_objects"))
              | map({resource: (if (.l.group // "") != "" then .l.resource + "." + .l.group else .l.resource end), count: .v})
              | group_by(.resource) | map(.[0]) | sort_by(-.count) | .[0:20]),
    process: {
      resident_memory_mib: (ser($last; "process_resident_memory_bytes") | .[0].v | mib),
      cpu_cores: (ser($cum; "process_cpu_seconds_total") | .[0].v | if . == null then null else per_s end),
      goroutines: (ser($last; "go_goroutines") | .[0].v),
      uptime_s: (if $st1 != null then ($now - $st1 | floor) else null end)
    },
    watch_events_per_second: (ser($cum; "apiserver_watch_events_total") | total | per_s),
    tls_handshake_errors: (ser($cum; "apiserver_tls_handshake_errors_total") | total),
    authentication: ([ser($cum; "authentication_attempts")[] | {key: .l.result, value: .v}]
                     | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries)
  }
JQ

define JQ_NODE_STATS <<'JQ'
$summary[0] as $s | $cad[0] as $c | $prb[0] as $p | $kub[0] as $k
| def hist1($name): [$k[] | select(.n == $name)] | if length == 0 then null else hgroup({}) | .[0] | hsum end;
{
  node: $node,
  summary: $s,
  throttle: ([$c[] | select(.n | startswith("container_cpu_cfs"))]
             | group_by([.l.namespace, .l.pod, .l.container])
             | map({namespace: .[0].l.namespace, pod: .[0].l.pod, container: .[0].l.container,
                    periods: ([.[] | select(.n == "container_cpu_cfs_periods_total") | .v] | add // 0),
                    throttled_periods: ([.[] | select(.n == "container_cpu_cfs_throttled_periods_total") | .v] | add // 0),
                    throttled_seconds: ([.[] | select(.n == "container_cpu_cfs_throttled_seconds_total") | .v] | add // 0)})),
  oom: ([$c[] | select(.n == "container_oom_events_total" and .v > 0)
         | {namespace: .l.namespace, pod: .l.pod, container: .l.container, count: .v}]),
  probes: ([$p[] | select(.n == "prober_probe_total" and .l.result != "successful" and .v > 0)
            | {namespace: .l.namespace, pod: .l.pod, container: .l.container,
               probe_type: (.l.probe_type | ascii_downcase), result: .l.result, count: .v}]),
  kubelet: {
    version: ([$k[] | select(.n == "kubernetes_build_info") | .l.git_version] | .[0]),
    running_pods: ([$k[] | select(.n == "kubelet_running_pods") | .v] | .[0]),
    running_containers: ([$k[] | select(.n == "kubelet_running_containers" and .l.container_state == "running") | .v] | .[0]),
    pleg_relist: hist1("kubelet_pleg_relist_duration_seconds_bucket"),
    pod_start: ((hist1("kubelet_pod_start_sli_duration_seconds_bucket") | if . != null and .count > 0 then . else null end)
                // hist1("kubelet_pod_start_duration_seconds_bucket")),
    runtime_errors: ([$k[] | select(.n == "kubelet_runtime_operations_errors_total" and .v > 0)
                      | {operation: .l.operation_type, count: .v}]),
    runtime_latency: ([$k[] | select(.n == "kubelet_runtime_operations_duration_seconds_bucket")]
                      | hgroup({operation: .l.operation_type}) | map(.key + hsum) | map(select(.count > 0))
                      | sort_by(-(.p99_ms // 0)) | .[0:5]),
    evictions: ([$k[] | select(.n == "kubelet_evictions" and .v > 0) | {signal: .l.eviction_signal, count: .v}]),
    storage_errors: ([$k[] | select(.n == "storage_operation_duration_seconds_count" and (.l.status // "success") != "success" and .v > 0)
                      | {operation: .l.operation_name, plugin: .l.volume_plugin, status: .l.status, count: .v}])
  }
}
JQ

define JQ_CONTAINERS <<'JQ'
def ckey: .namespace + "/" + .pod + "/" + .container;
$nstats[0] as $N
| ([$N[] | (.summary.pods // [])[] as $p | ($p.containers // [])[]
    | {key: ($p.podRef.namespace + "/" + $p.podRef.name + "/" + .name),
       value: {cpu_m: (.cpu.usageNanoCores | if . == null then null else . / 1000000 end),
               mem_ws: .memory.workingSetBytes, mem_rss: .memory.rssBytes,
               rootfs: .rootfs.usedBytes, logs: .logs.usedBytes, source: "kubelet-summary"}}] | from_entries) as $usage
| ([($ms[0].items // [])[] as $p | ($p.containers // [])[]
    | {key: ($p.metadata.namespace + "/" + $p.metadata.name + "/" + .name),
       value: {cpu_m: (.usage.cpu | cpu_m), mem_ws: (.usage.memory | bytes), source: "metrics-server"}}] | from_entries) as $msu
| ([$N[] | .throttle[] | {key: ckey, value: .}] | from_entries) as $thr
| ([$N[] | .oom[]] | group_by(ckey) | map({key: (.[0] | ckey), value: (map(.count) | add)}) | from_entries) as $oom
| ([$N[] | .probes[]] | group_by(ckey)
   | map({key: (.[0] | ckey), value: (group_by(.probe_type) | map({key: .[0].probe_type, value: (map(.count) | add)}) | from_entries)})
   | from_entries) as $prb
| [ $pods[0].items[] as $p
    | ($p.metadata.namespace + "/" + $p.metadata.name) as $pk
    | ([($p.spec.initContainers // [])[] | {c: ., type: (if .restartPolicy == "Always" then "sidecar" else "init" end),
                                             st: ($p.status.initContainerStatuses // [])}]
       + [($p.spec.containers // [])[] | {c: ., type: "app", st: ($p.status.containerStatuses // [])}])[]
    | .c as $c | .type as $type
    | (.st | map(select(.name == $c.name)) | .[0]) as $s
    | ($pk + "/" + $c.name) as $key
    | ($usage[$key] // $msu[$key]) as $u
    | $thr[$key] as $th
    | {
        namespace: $p.metadata.namespace, pod: $p.metadata.name, container: $c.name, type: $type,
        node: ($p.spec.nodeName // ""), pod_phase: ($p.status.phase // "Unknown"),
        pod_reason: ($p.status.reason // ""), qos: ($p.status.qosClass // ""),
        owner: (($p.metadata.ownerReferences // [])[0] | if . == null then "" else .kind + "/" + .name end),
        image: ($c.image // ""),
        ready: ($s.ready // false),
        state: (($s.state // {}) | keys | .[0] // "none"),
        reason: ($s.state.waiting.reason // $s.state.terminated.reason // ""),
        message: (($s.state.waiting.message // $s.state.terminated.message // "") | one_line | trunc(300)),
        exit_code: $s.state.terminated.exitCode,
        restarts: ($s.restartCount // 0),
        last_reason: ($s.lastState.terminated.reason // ""),
        last_exit_code: $s.lastState.terminated.exitCode,
        last_finished: ($s.lastState.terminated.finishedAt // ""),
        last_message: (($s.lastState.terminated.message // "") | one_line | trunc(300)),
        started_at: ($s.state.running.startedAt // ""),
        cpu_request_m: ($c.resources.requests.cpu | cpu_m),
        cpu_limit_m: ($c.resources.limits.cpu | cpu_m),
        mem_request_mib: ($c.resources.requests.memory | bytes | mib),
        mem_limit_mib: ($c.resources.limits.memory | bytes | mib),
        cpu_usage_m: ($u.cpu_m | rnd(1)),
        mem_working_set_mib: ($u.mem_ws | mib),
        mem_rss_mib: ($u.mem_rss | mib),
        rootfs_mib: ($u.rootfs | mib),
        logs_mib: ($u.logs | mib),
        usage_source: ($u.source // ""),
        cpu_throttled_pct: (if $th != null and $th.periods > 0 then pct($th.throttled_periods; $th.periods) else null end),
        cpu_throttled_seconds: ($th.throttled_seconds | rnd(1)),
        cpu_periods: $th.periods,
        oom_events: ($oom[$key] // 0),
        probe_failures: ($prb[$key] // {})
      }
    | .cpu_pct_of_request = pct(.cpu_usage_m; .cpu_request_m)
    | .cpu_pct_of_limit = pct(.cpu_usage_m; .cpu_limit_m)
    | .mem_pct_of_request = pct(.mem_working_set_mib; .mem_request_mib)
    | .mem_pct_of_limit = pct(.mem_working_set_mib; .mem_limit_mib)
  ]
JQ

define JQ_NODES <<'JQ'
def sumq(f): [.[] | f | select(. != null)] | add // 0;
([$pods[0].items[] | select(.spec.nodeName != null and (.status.phase | IN("Succeeded", "Failed") | not))]
  | group_by(.spec.nodeName) | map({key: .[0].spec.nodeName, value: .}) | from_entries) as $by_node
| ($nstats[0] | map({key: .node, value: .}) | from_entries) as $st
| ([$calls[0][] | select(.phase == "node")] | map({key: .id, value: .status}) | from_entries) as $cs
| ((($nodes[0].items // []) | length) > 0) as $have_objects
| (if $have_objects then $nodes[0].items
   else [$nstats[0][] | {metadata: {name: .node}, status: {}, spec: {}}] end)
| map(. as $n | $n.metadata.name as $name | ($by_node[$name] // []) as $np | $st[$name] as $x
    | ($x.summary.node // null) as $sn
    | [$np[] | (.spec.containers // [])[]] as $ctrs
    | {
        node: $name,
        roles: ([($n.metadata.labels // {}) | keys[] | select(startswith("node-role.kubernetes.io/"))
                 | ltrimstr("node-role.kubernetes.io/")] | join(",") | if . == "" then "none" else . end),
        node_object: $have_objects,
        ready: (if $have_objects then ([($n.status.conditions // [])[] | select(.type == "Ready") | .status] | .[0] // "Unknown") else null end),
        conditions: [($n.status.conditions // [])[]
                     | select((.type == "Ready" and .status != "True") or (.type != "Ready" and .status == "True"))
                     | {type, status, reason: (.reason // ""), message: (.message // "" | one_line)}],
        unschedulable: ($n.spec.unschedulable // false),
        kubelet_version: ($n.status.nodeInfo.kubeletVersion // $x.kubelet.version // ""),
        container_runtime: ($n.status.nodeInfo.containerRuntimeVersion // ""),
        os_image: ($n.status.nodeInfo.osImage // ""),
        kernel: ($n.status.nodeInfo.kernelVersion // ""),
        cpu_allocatable_m: ($n.status.allocatable.cpu | cpu_m),
        mem_allocatable_mib: ($n.status.allocatable.memory | bytes | mib),
        pods_allocatable: ($n.status.allocatable.pods | if . == null then null else tonumber end),
        pods: ($np | length),
        cpu_requests_m: ($ctrs | sumq(.resources.requests.cpu | cpu_m)),
        cpu_limits_m: ($ctrs | sumq(.resources.limits.cpu | cpu_m)),
        mem_requests_mib: ($ctrs | sumq(.resources.requests.memory | bytes) | mib),
        mem_limits_mib: ($ctrs | sumq(.resources.limits.memory | bytes) | mib),
        cpu_usage_m: ($sn.cpu.usageNanoCores | if . == null then null else . / 1000000 | rnd(0) end),
        mem_working_set_mib: ($sn.memory.workingSetBytes | mib),
        fs_used_pct: pct($sn.fs.usedBytes; $sn.fs.capacityBytes),
        imagefs_used_pct: pct($sn.runtime.imageFs.usedBytes; $sn.runtime.imageFs.capacityBytes),
        pids_running: $sn.rlimit.curproc,
        pids_max: $sn.rlimit.maxpid,
        net_rx_errors: ([$sn.network.interfaces[]? | .rxErrors // 0] | add),
        net_tx_errors: ([$sn.network.interfaces[]? | .txErrors // 0] | add),
        stats: {summary: ($cs["node:" + $name + ":summary"] // "not-collected"),
                cadvisor: ($cs["node:" + $name + ":cadvisor"] // "not-collected"),
                probes: ($cs["node:" + $name + ":probes"] // "not-collected"),
                kubelet: ($cs["node:" + $name + ":kubelet"] // "not-collected")},
        kubelet: ($x.kubelet // null)
      }
    | .cpu_requests_pct = pct(.cpu_requests_m; .cpu_allocatable_m)
    | .cpu_limits_pct = pct(.cpu_limits_m; .cpu_allocatable_m)
    | .mem_requests_pct = pct(.mem_requests_mib; .mem_allocatable_mib)
    | .mem_limits_pct = pct(.mem_limits_mib; .mem_allocatable_mib)
    | .cpu_usage_pct = pct(.cpu_usage_m; .cpu_allocatable_m)
    | .mem_usage_pct = pct(.mem_working_set_mib; .mem_allocatable_mib)
    | .pid_pct = pct(.pids_running; .pids_max))
JQ

define JQ_EVENTS <<'JQ'
def ev_count: (.series.count // .count // 1);
def ev_last: (.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp // "");
def ev_first: (.firstTimestamp // .eventTime // .metadata.creationTimestamp // "");
def category: .reason as $r | .message as $m
  | if ($m | test("timed out|timeout|deadline exceeded"; "i")) then "timeout"
    elif ($r | IN("Unhealthy", "ProbeWarning")) then "probe"
    elif ($r | IN("FailedScheduling", "NotTriggerScaleUp", "FailedPreemption")) then "scheduling"
    elif ($r | IN("OOMKilling", "SystemOOM")) or ($m | test("OOMKilled|out of memory"; "i")) then "oom"
    elif ($r | IN("ErrImagePull", "ImagePullBackOff", "InspectFailed", "ErrImageNeverPull"))
         or (($r | IN("Failed", "BackOff")) and ($m | test("image"; "i"))) then "image"
    elif $r == "BackOff" then "crashloop"
    elif ($m | test("exceeded quota"; "i")) then "quota"
    elif ($r | test("Mount|Attach|Volume|Provision|Binding")) then "storage"
    elif ($r | IN("FailedCreatePodSandBox", "FailedKillPod", "NetworkNotReady", "FailedToCreateEndpoint",
                  "DNSConfigForming", "FailedCreatePodContainer")) then "network"
    elif ($r | test("^Node|Evict|Rebooted|GCFailed|InvalidDiskCapacity|FreeDiskSpaceFailed|KubeletSetupFailed")) then "node"
    elif ($r | test("BackoffLimitExceeded|DeadlineExceeded|JobFailed|PodFailurePolicy")) then "job"
    elif ($r | test("FailedGetResourceMetric|FailedComputeMetricsReplicas|FailedGetScale|FailedRescale|FailedGetExternalMetric")) then "autoscaling"
    elif $r == "Failed" and ($m | test("configmap|secret|not found"; "i")) then "config"
    elif ($r | IN("FailedCreate", "FailedDelete", "FailedUpdate", "FailedSync")) then "controller"
    else "other" end;
[($ev[0].items // [])[] | {
    namespace: (.involvedObject.namespace // .metadata.namespace // ""),
    kind: (.involvedObject.kind // ""), name: (.involvedObject.name // ""),
    type: (.type // "Normal"), reason: (.reason // ""), message: (.message // "" | one_line),
    count: ev_count, first_seen: ev_first, last_seen: ev_last,
    source: (.source.component // .reportingComponent // ""),
    host: (.source.host // .reportingInstance // "")}
  | .category = (if .type == "Warning" then category else "normal" end)] as $all
| ($all | group_by([.namespace, .kind, .name, .reason, .type])
   | map((sort_by(.last_seen) | last) + {count: (map(.count) | add), first_seen: (map(.first_seen) | min)})) as $groups
| ($groups | map(select(.type == "Warning"))) as $warn
| {
    total: ($all | map(.count) | add // 0),
    warning: ($warn | map(.count) | add // 0),
    normal: ($groups | map(select(.type != "Warning") | .count) | add // 0),
    by_reason: ($warn | group_by(.reason)
                | map({reason: .[0].reason, category: (map(.category) | unique | join(",")), count: (map(.count) | add), objects: length,
                       namespaces: (map(.namespace) | unique | length),
                       example: (sort_by(.last_seen) | last | .message | trunc(200))})
                | sort_by(-.count)),
    by_category: ($warn | group_by(.category) | map({category: .[0].category, count: (map(.count) | add)}) | sort_by(-.count)),
    groups: ($groups | sort_by(.last_seen) | reverse)
  }
JQ

define JQ_NAMESPACES <<'JQ'
def cnt(f): map(select(f)) | length;
$pods[0].items as $P
| ([($nslist[0].items // [])[] | .metadata.name] + [$P[] | .metadata.namespace] + $scope | unique) as $all
| (if ($scope | length) > 0 then [$all[] | select(IN($scope[]))] else $all end) as $names
| ($containers[0] | group_by(.namespace) | map({key: .[0].namespace, value: .}) | from_entries) as $C
| ($P | group_by(.metadata.namespace) | map({key: .[0].metadata.namespace, value: .}) | from_entries) as $PP
| ($events[0].groups | map(select(.type == "Warning")) | group_by(.namespace)
   | map({key: .[0].namespace, value: (map(.count) | add)}) | from_entries) as $W
| (($quotas[0].items // []) | group_by(.metadata.namespace) | map({key: .[0].metadata.namespace, value: .}) | from_entries) as $Q
| [ $names[] as $ns
    | ($PP[$ns] // []) as $p
    | ($C[$ns] // []) as $c
    | ($c | map(select(.type != "init"))) as $ac
    | ($ac | map(select(.pod_phase | IN("Succeeded", "Failed") | not))) as $live
    | {
        namespace: $ns,
        pods: ($p | length),
        running: ($p | cnt(.status.phase == "Running")),
        pending: ($p | cnt(.status.phase == "Pending")),
        failed: ($p | cnt(.status.phase == "Failed")),
        succeeded: ($p | cnt(.status.phase == "Succeeded")),
        unknown: ($p | cnt(.status.phase == "Unknown")),
        containers: ($ac | length),
        containers_not_ready: ($live | cnt(.pod_phase == "Running" and (.ready | not))),
        restarts: ($c | map(.restarts) | add // 0),
        cpu_usage_m: ($live | map(.cpu_usage_m | select(. != null)) | add | if . == null then null else rnd(1) end),
        mem_usage_mib: ($live | map(.mem_working_set_mib | select(. != null)) | add | if . == null then null else rnd(1) end),
        cpu_requests_m: ($live | map(.cpu_request_m // 0) | add // 0 | rnd(1)),
        cpu_limits_m: ($live | map(.cpu_limit_m // 0) | add // 0 | rnd(1)),
        mem_requests_mib: ($live | map(.mem_request_mib // 0) | add // 0 | rnd(1)),
        mem_limits_mib: ($live | map(.mem_limit_mib // 0) | add // 0 | rnd(1)),
        containers_without_requests: ($live | cnt(.cpu_request_m == null and .mem_request_mib == null)),
        warning_events: ($W[$ns] // 0),
        quotas: [($Q[$ns] // [])[] as $q | ($q.status.hard // {}) | to_entries[] | .key as $r
                 | {quota: $q.metadata.name, resource: $r, hard: .value, used: ($q.status.used[$r] // "0")}
                 | .pct = pct(.used | qty($r); .hard | qty($r))]
      }
    | .cpu_pct_of_requests = pct(.cpu_usage_m; .cpu_requests_m)
    | .mem_pct_of_requests = pct(.mem_usage_mib; .mem_requests_mib)
    | .quota_max_pct = ([.quotas[].pct | select(. != null)] | max)
  ]
JQ

define JQ_API_CLIENT <<'JQ'
[$calls[0][] | select(.phase == "probe")]
| group_by(.id | split(":")[1])
| map((.[0].id | split(":")[1]) as $name
    | map(select(.status == "ok")) as $ok
    | ($ok | map(.http_ms // .wall_ms)) as $lat
    | {
        endpoint: $name, path: .[0].target, samples: length, ok: ($ok | length),
        timeouts: (map(select(.status == "timeout")) | length),
        forbidden: (map(select(.status | IN("forbidden", "unauthorized"))) | length),
        errors: (map(select(.status | IN("ok", "timeout", "forbidden", "unauthorized") | not)) | length),
        min_ms: ($lat | min), p50_ms: ($lat | nearest(0.5)), p90_ms: ($lat | nearest(0.9)),
        p99_ms: ($lat | nearest(0.99)), max_ms: ($lat | max),
        avg_ms: (if ($lat | length) > 0 then ($lat | add / length | rnd(1)) else null end),
        avg_wall_ms: (if ($ok | length) > 0 then ($ok | map(.wall_ms) | add / length | rnd(1)) else null end),
        failures: (map(select(.status != "ok")) | group_by(.status)
                   | map({status: .[0].status, count: length, message: (.[0].message | trunc(200))}))
      })
JQ

define JQ_FAILURES <<'JQ'
def f($sev; $cat; $scope; $ns; $obj; $reason; $msg):
  {severity: $sev, category: $cat, scope: $scope, namespace: ($ns // ""), object: $obj, reason: $reason,
   message: ($msg | one_line | trunc(600))};
def sevrank: {"critical": 0, "warning": 1, "info": 2}[.] // 3;
def failed_checks: [scan("\\[-\\]([^\\[\\n\\\\\"]+)") | .[0] | sub("\\s+$"; "")];
def kv: to_entries | map("\(.key)=\(.value)") | join(", ");
$th as $T
| [
  # ---------------------------------------------------- API server health
  ( [{name: "livez", text: $livez}, {name: "readyz", text: $readyz}][]
    | .name as $nm | ([$calls[0][] | select(.id == $nm)] | .[0]) as $call
    | select($call != null)
    | (.text | failed_checks) as $fc
    | if $call.status != "ok" or ($fc | length) > 0 then
        f("critical"; "api-health"; "api"; ""; "/" + $nm; "APIServerHealthCheckFailed";
          "status=\($call.status); failing checks: \(if ($fc | length) > 0 then $fc | join("; ") else $call.message end)")
      else empty end ),

  # ------------------------------------------------- client-side API probes
  ( $client[0][]
    | (if .timeouts > 0 then f("critical"; "timeout"; "api"; ""; .path; "APIClientTimeout";
         "\(.timeouts)/\(.samples) requests to \(.path) timed out (request timeout \($timeout)s)") else empty end),
      (if .errors > 0 then f("warning"; "api-error"; "api"; ""; .path; "APIClientErrors";
         "\(.errors)/\(.samples) requests failed: "
         + ([.failures[] | select(.status | IN("timeout", "forbidden", "unauthorized") | not)]
            | map("\(.status) x\(.count): \(.message)") | join("; "))) else empty end),
      (if .forbidden > 0 then f("info"; "rbac"; "api"; ""; .path; "APIClientForbidden";
         "\(.forbidden)/\(.samples) requests were forbidden for this identity - latency not measured") else empty end),
      (if .p99_ms != null and .p99_ms >= $T.api_slow_ms then f("warning"; "latency"; "api"; ""; .path; "APIClientSlow";
         "p99 \(.p99_ms)ms >= \($T.api_slow_ms)ms (p50 \(.p50_ms)ms, max \(.max_ms)ms, n=\(.ok))") else empty end) ),

  # -------------------------------------------------- API server /metrics
  ( $api[0] as $a
    | if ($a.available | not) then
        f("info"; "data"; "api"; ""; "/metrics"; "APIServerMetricsUnavailable";
          "kube-apiserver /metrics unavailable (scrape 1: \([$calls[0][] | select(.id == "metrics:apiserver:start") | .status] | .[0] // "skipped"), scrape 2: \([$calls[0][] | select(.id == "metrics:apiserver:end") | .status] | .[0] // "skipped")); server-side API measurements are missing")
      else
        (if $a.instance_changed then f("info"; "data"; "api"; ""; "/metrics"; "APIServerInstanceChanged";
           "the two /metrics scrapes reached different kube-apiserver instances (HA control plane); counters are cumulative since that instance started") else empty end),
        (if $a.requests.code_5xx > 0 then f("warning"; "api-error"; "api"; ""; "kube-apiserver"; "APIServer5xx";
           "\($a.requests.code_5xx) responses with 5xx (\($a.requests.error_ratio_pct)% of \($a.requests.total)) over \($a.seconds_covered)s; top: "
           + ([$a.error_series[] | select(.code | startswith("5"))] | .[0:5] | map("\(.verb) \(.resource) \(.code) x\(.count)") | join(", "))) else empty end),
        (if $a.requests.code_429 > 0 then f("warning"; "throttling"; "api"; ""; "kube-apiserver"; "APIServerThrottled429";
           "\($a.requests.code_429) requests rejected with 429 Too Many Requests over \($a.seconds_covered)s; top: "
           + ([$a.error_series[] | select(.code == "429")] | .[0:5] | map("\(.verb) \(.resource) x\(.count)") | join(", "))) else empty end),
        ([$a.terminations[] | select(.code != "429")] as $t
         | if ($t | length) > 0 then f("warning"; "timeout"; "api"; ""; "kube-apiserver"; "APIRequestsTerminated";
             "requests terminated by the API server (504 = request timeout; 429s are reported separately): "
             + ($t[0:5] | map("\(.verb) \(.resource) code=\(.code) x\(.count)") | join(", "))) else empty end),
        (if ($a.aborts | length) > 0 then f("warning"; "timeout"; "api"; ""; "kube-apiserver"; "APIRequestsAborted";
           "requests aborted by the timeout handler: " + ($a.aborts[0:5] | map("\(.verb) \(.resource) x\(.count)") | join(", "))) else empty end),
        (if ($a.apf.rejected | length) > 0 then f("warning"; "throttling"; "api"; ""; "kube-apiserver"; "APFRejectedRequests";
           "API Priority and Fairness rejected requests: "
           + ($a.apf.rejected[0:5] | map("\(.priority_level)/\(.flow_schema) reason=\(.reason) x\(.count)") | join(", "))) else empty end),
        ($a.apf.wait[] | select(.p99_ms != null and .p99_ms >= $T.apf_wait_ms)
         | f("warning"; "latency"; "api"; ""; "priority-level/" + .priority_level; "APFQueueWaitHigh";
             "p99 queue wait \(.p99_ms)ms over \(.count) requests")),
        ($a.latency[] | select(.slo_breach)
         | f("warning"; "latency"; "api"; ""; "\(.verb) \(.resource)"; "APILatencySLOBreach";
             "p99 \(.p99_ms)ms > SLO \(.slo_ms)ms (scope=\(.scope), requests=\(.count), p50 \(.p50_ms)ms)")),
        ($a.etcd.by_operation[] | select(.p99_ms != null and .p99_ms >= $T.etcd_slow_ms)
         | f("warning"; "latency"; "api"; ""; "etcd/" + .operation; "EtcdSlow";
             "etcd \(.operation) p99 \(.p99_ms)ms >= \($T.etcd_slow_ms)ms over \(.count) requests")),
        (if ($a.etcd.errors | length) > 0 then f("warning"; "api-error"; "api"; ""; "etcd"; "EtcdRequestErrors";
           "etcd request errors: " + ($a.etcd.errors[0:5] | map("\(.operation) \(.resource) x\(.count)") | join(", "))) else empty end),
        ($a.webhooks.latency[] | select(.p99_ms != null and .p99_ms >= $T.webhook_slow_ms)
         | f("warning"; "latency"; "api"; ""; "webhook/" + .name; "AdmissionWebhookSlow";
             "\(.type) webhook p99 \(.p99_ms)ms on \(.operation) (n=\(.count))")),
        ($a.webhooks.rejections[] | f("info"; "admission"; "api"; ""; "webhook/" + .name; "AdmissionWebhookRejections";
             "\(.count) \(.operation) requests rejected (\(.error_type), code \(.code))")),
        ($a.webhooks.fail_open[] | f("warning"; "admission"; "api"; ""; "webhook/" + .name; "AdmissionWebhookFailOpen";
             "\(.count) requests admitted because the \(.type) webhook failed open")),
        (if (($a.authentication.failure // 0) + ($a.authentication.error // 0)) > 0 then
           f("info"; "security"; "api"; ""; "kube-apiserver"; "AuthenticationFailures";
             "authentication failures=\($a.authentication.failure // 0) errors=\($a.authentication.error // 0) over \($a.seconds_covered)s") else empty end),
        (if $a.tls_handshake_errors > 0 then f("info"; "network"; "api"; ""; "kube-apiserver"; "TLSHandshakeErrors";
           "\($a.tls_handshake_errors) TLS handshake errors over \($a.seconds_covered)s") else empty end)
      end ),

  # ------------------------------------------------------------------ nodes
  ( $nodes_a[0][] as $n | ("node/" + $n.node) as $obj
    | (if $n.ready != null and $n.ready != "True" then f("critical"; "node"; "node"; ""; $obj; "NodeNotReady";
         ([$n.conditions[] | select(.type == "Ready")] | .[0] | "\(.reason // "") \(.message // "")")) else empty end),
      ($n.conditions[] | select(.type != "Ready")
       | f(if .type | IN("MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable") then "critical" else "warning" end;
           "node"; "node"; ""; $obj; "Node" + .type; "\(.reason): \(.message)")),
      (if $n.unschedulable then f("info"; "node"; "node"; ""; $obj; "NodeCordoned"; "node is cordoned (spec.unschedulable=true)") else empty end),
      (if ($n.cpu_usage_pct // 0) >= $T.node_cpu_pct then f("warning"; "cpu"; "node"; ""; $obj; "NodeCPUHigh";
         "CPU usage \($n.cpu_usage_m)m = \($n.cpu_usage_pct)% of allocatable \($n.cpu_allocatable_m)m") else empty end),
      (if ($n.mem_usage_pct // 0) >= $T.node_mem_pct then f("warning"; "memory"; "node"; ""; $obj; "NodeMemoryHigh";
         "memory working set \($n.mem_working_set_mib)Mi = \($n.mem_usage_pct)% of allocatable \($n.mem_allocatable_mib)Mi") else empty end),
      (if ($n.fs_used_pct // 0) >= $T.node_disk_pct or ($n.imagefs_used_pct // 0) >= $T.node_disk_pct then
         f("warning"; "storage"; "node"; ""; $obj; "NodeDiskHigh"; "node fs \($n.fs_used_pct)% used, image fs \($n.imagefs_used_pct)% used") else empty end),
      (if ($n.pid_pct // 0) >= $T.node_pid_pct then f("warning"; "node"; "node"; ""; $obj; "NodePIDsHigh";
         "\($n.pids_running)/\($n.pids_max) PIDs in use (\($n.pid_pct)%)") else empty end),
      ([$n.stats[] | select(. != "ok" and . != "not-collected")] as $bad
       | if ($bad | length) == 0 then empty
         elif ([$bad[] | select(IN("forbidden", "unauthorized") | not)] | length) == 0 then
           f("info"; "rbac"; "node"; ""; $obj; "NodeStatsForbidden"; "no permission for nodes/proxy - container usage, throttling, OOM and probe counters unavailable: " + ($n.stats | kv))
         else
           f("warning"; "data"; "node"; ""; $obj; "NodeStatsUnavailable"; "kubelet endpoints via node proxy: " + ($n.stats | kv))
         end),
      ($n.kubelet // {}
       | (if (.runtime_errors // [] | length) > 0 then f("warning"; "runtime"; "node"; ""; $obj; "KubeletRuntimeErrors";
            "container runtime operation errors: " + (.runtime_errors | map("\(.operation) x\(.count)") | join(", "))) else empty end),
         (if (.evictions // [] | length) > 0 then f("warning"; "eviction"; "node"; ""; $obj; "KubeletEvictions";
            "pods evicted: " + (.evictions | map("\(.signal) x\(.count)") | join(", "))) else empty end),
         (if (.pleg_relist.p99_ms // 0) >= $T.pleg_slow_ms then f("warning"; "latency"; "node"; ""; $obj; "KubeletPLEGSlow";
            "PLEG relist p99 \(.pleg_relist.p99_ms)ms >= \($T.pleg_slow_ms)ms") else empty end),
         (if (.storage_errors // [] | length) > 0 then f("warning"; "storage"; "node"; ""; $obj; "VolumeOperationErrors";
            (.storage_errors | map("\(.operation) \(.plugin) \(.status) x\(.count)") | join(", "))) else empty end)),
      (if (($n.net_rx_errors // 0) + ($n.net_tx_errors // 0)) > 0 then f("info"; "network"; "node"; ""; $obj; "NodeNetworkErrors";
         "rx_errors=\($n.net_rx_errors) tx_errors=\($n.net_tx_errors)") else empty end) ),

  # ------------------------------------------------------------- containers
  ( $containers[0][] | "pod/\(.pod) container/\(.container)" as $obj
    | (if .reason == "CrashLoopBackOff" then f("critical"; "crashloop"; "container"; .namespace; $obj; "CrashLoopBackOff";
         "restarts=\(.restarts); last termination: \(.last_reason) exit=\(.last_exit_code // "?") \(.last_message)") else empty end),
      (if .reason | IN("ImagePullBackOff", "ErrImagePull", "InvalidImageName", "ErrImageNeverPull", "RegistryUnavailable", "ImageInspectError") then
         f("critical"; "image"; "container"; .namespace; $obj; .reason; "image \(.image): \(.message)") else empty end),
      (if .reason | IN("CreateContainerConfigError", "CreateContainerError", "RunContainerError", "PostStartHookError",
                       "PreStopHookError", "ContainerCannotRun", "StartError") then
         f("critical"; "config"; "container"; .namespace; $obj; .reason; .message) else empty end),
      (if .reason == "OOMKilled" or .last_reason == "OOMKilled" or .oom_events > 0 then
         f("critical"; "oom"; "container"; .namespace; $obj; "OOMKilled";
           "memory limit \(if .mem_limit_mib == null then "none" else "\(.mem_limit_mib)Mi" end), "
           + "working set \(if .mem_working_set_mib == null then "n/a (container not running)" else "\(.mem_working_set_mib)Mi" end), "
           + "restarts=\(.restarts), last OOM kill \(if .last_finished == "" then "now" else .last_finished end)") else empty end),
      (if .restarts >= $T.restart_count and .reason != "CrashLoopBackOff" then
         (.last_finished | minutes_since($now)) as $ago
         | if $ago != null and $ago <= $T.restart_recent_minutes then
             f("critical"; "crashloop"; "container"; .namespace; $obj; "CrashLooping";
               "restarts=\(.restarts), last restart \($ago) min ago (\(.last_reason) exit=\(.last_exit_code // "?")); currently \(.state) - flapping between running and back-off")
           else
             f("warning"; "restarts"; "container"; .namespace; $obj; "HighRestartCount";
               "restarts=\(.restarts); last termination: \(.last_reason) exit=\(.last_exit_code // "?") at \(.last_finished)")
           end
       else empty end),
      (if .type == "app" and .pod_phase == "Running" and .state == "running" and (.ready | not) then
         f("warning"; "readiness"; "container"; .namespace; $obj; "ContainerNotReady";
           "running but not ready" + (if (.probe_failures | length) > 0 then "; probe failures: " + (.probe_failures | kv) else "" end)) else empty end),
      (if ((.probe_failures.liveness // 0) + (.probe_failures.startup // 0)) > 0 then
         f("warning"; "probe"; "container"; .namespace; $obj; "LivenessProbeFailures";
           "liveness failures=\(.probe_failures.liveness // 0), startup failures=\(.probe_failures.startup // 0) (kubelet counters)") else empty end),
      (if .mem_pct_of_limit != null and .mem_pct_of_limit >= $T.mem_limit_pct then
         f("warning"; "memory"; "container"; .namespace; $obj; "MemoryNearLimit";
           "working set \(.mem_working_set_mib)Mi = \(.mem_pct_of_limit)% of limit \(.mem_limit_mib)Mi - OOM kill risk") else empty end),
      (if .cpu_throttled_pct != null and .cpu_throttled_pct >= $T.cpu_throttle_pct and (.cpu_periods // 0) >= $T.throttle_min_periods then
         f("warning"; "cpu"; "container"; .namespace; $obj; "CPUThrottling";
           "\(.cpu_throttled_pct)% of CFS periods throttled (limit \(.cpu_limit_m)m, usage \(.cpu_usage_m // "?")m, \(.cpu_throttled_seconds)s throttled)") else empty end) ),

  # ------------------------------------------------------------------- pods
  ( $pods[0].items[] | ("pod/" + .metadata.name) as $obj | .metadata.namespace as $ns
    | ([.status.conditions[]? | select(.type == "PodScheduled")] | .[0]) as $sched
    | (.metadata.creationTimestamp | minutes_since($now)) as $age
    | [((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[] | .state.waiting.reason // empty] as $waiting
    | (if .status.phase == "Pending" and ($sched.status // "") == "False" then
         f("critical"; "scheduling"; "pod"; $ns; $obj; ($sched.reason // "Unschedulable"); "pending \($age) min: \($sched.message // "")") else empty end),
      (if .status.phase == "Pending" and ($sched.status // "True") == "True" and ($age // 0) >= $T.pending_minutes
          and ([$waiting[] | select(IN("ContainerCreating", "PodInitializing") | not)] | length) == 0 then
         f("warning"; "startup"; "pod"; $ns; $obj; "PodPendingTooLong";
           "scheduled but pending for \($age) min (containers waiting: \($waiting | unique | join(",")))") else empty end),
      (if .status.phase == "Failed" then
         f("warning"; (if .status.reason == "Evicted" then "eviction" else "failed" end); "pod"; $ns; $obj; (.status.reason // "PodFailed");
           ((.status.message // "") + " " + ([(.status.containerStatuses // [])[] | select(.state.terminated != null)
             | "\(.name): \(.state.terminated.reason) exit=\(.state.terminated.exitCode) \(.state.terminated.message // "")"] | join("; ")))) else empty end),
      (if .status.phase == "Unknown" then f("critical"; "node"; "pod"; $ns; $obj; "PodUnknown";
         "pod phase Unknown - node \(.spec.nodeName // "?") is probably unreachable") else empty end),
      (if .metadata.deletionTimestamp != null and ((.metadata.deletionTimestamp | minutes_since($now)) // 0) > 5 then
         f("warning"; "termination"; "pod"; $ns; $obj; "PodStuckTerminating";
           "deletion requested \(.metadata.deletionTimestamp | minutes_since($now)) min ago") else empty end) ),

  # -------------------------------------------------------------- workloads
  ( $deploy[0].items[]? | ("deployment/" + .metadata.name) as $obj | .metadata.namespace as $ns
    | (.spec.replicas // 1) as $want | (.status.availableReplicas // 0) as $have
    | (if $want > $have then f("warning"; "workload"; "workload"; $ns; $obj; "DeploymentUnavailable";
         "\($have)/\($want) replicas available (updated=\(.status.updatedReplicas // 0), unavailable=\(.status.unavailableReplicas // 0))") else empty end),
      ((.status.conditions // [])[] | select(.type == "Progressing" and .status == "False")
       | f("critical"; "workload"; "workload"; $ns; $obj; (.reason // "ProgressDeadlineExceeded"); .message // "")),
      ((.status.conditions // [])[] | select(.type == "ReplicaFailure" and .status == "True")
       | f("warning"; "workload"; "workload"; $ns; $obj; "ReplicaFailure"; "\(.reason // ""): \(.message // "")")) ),
  ( $sts[0].items[]? | select((.spec.replicas // 1) > (.status.readyReplicas // 0))
    | f("warning"; "workload"; "workload"; .metadata.namespace; "statefulset/" + .metadata.name; "StatefulSetNotReady";
        "\(.status.readyReplicas // 0)/\(.spec.replicas // 1) replicas ready") ),
  ( $ds[0].items[]? | select((.status.numberUnavailable // 0) > 0 or (.status.numberReady // 0) < (.status.desiredNumberScheduled // 0))
    | f("warning"; "workload"; "workload"; .metadata.namespace; "daemonset/" + .metadata.name; "DaemonSetUnavailable";
        "ready \(.status.numberReady // 0)/\(.status.desiredNumberScheduled // 0), unavailable \(.status.numberUnavailable // 0), misscheduled \(.status.numberMisscheduled // 0)") ),
  ( $jobs[0].items[]? | . as $j | (.status.conditions // [])[] | select(.type == "Failed" and .status == "True")
    | f("warning"; "job"; "workload"; $j.metadata.namespace; "job/" + $j.metadata.name; (.reason // "JobFailed");
        "\(.message // "") (failed pods: \($j.status.failed // 0))") ),
  ( $hpas[0].items[]? | . as $h | ("hpa/" + .metadata.name) as $obj
    | ((.status.conditions // [])[] | select((.type == "AbleToScale" or .type == "ScalingActive") and .status == "False")
       | f("warning"; "autoscaling"; "workload"; $h.metadata.namespace; $obj; (.reason // .type); .message // "")),
      (if (.status.currentReplicas // 0) >= (.spec.maxReplicas // 1000000000) then
         f("info"; "autoscaling"; "workload"; $h.metadata.namespace; $obj; "HPAAtMaxReplicas"; "running at maxReplicas=\(.spec.maxReplicas)") else empty end) ),

  # ---------------------------------------------------------------- storage
  ( $pvcs[0].items[]? | . as $v | select(.status.phase != "Bound")
    | ([$events[0].groups[] | select(.kind == "PersistentVolumeClaim" and .name == $v.metadata.name
                                     and .namespace == $v.metadata.namespace and .type == "Warning")] | sort_by(.last_seen) | last) as $e
    | f("warning"; "storage"; "workload"; .metadata.namespace; "pvc/" + .metadata.name; "PVC" + (.status.phase // "Unknown");
        "storageClass=\(.spec.storageClassName // "<default>"); \($e.reason // "no events"): \($e.message // "")") ),
  ( $nstats[0][] | (.summary.pods // [])[] as $p | ($p.volume // [])[]
    | select((.capacityBytes // 0) > 0)
    | select(((.usedBytes // 0) * 100 / .capacityBytes) >= $T.volume_pct
             or ((.inodes // 0) > 0 and ((.inodesUsed // 0) * 100 / .inodes) >= $T.volume_pct))
    | f("warning"; "storage"; "pod"; $p.podRef.namespace; "pod/\($p.podRef.name) volume/\(.name)"; "VolumeAlmostFull";
        "bytes \(pct(.usedBytes; .capacityBytes))% of \(.capacityBytes | mib)Mi used, inodes \(pct(.inodesUsed; .inodes))% used") ),

  # ------------------------------------------------------ namespaces/quotas
  ( $ns_a[0][] as $n | $n.quotas[] | select(.pct != null and .pct >= $T.quota_pct)
    | f("warning"; "quota"; "namespace"; $n.namespace; "resourcequota/" + .quota;
        (if .pct >= 100 then "QuotaExhausted" else "QuotaNearLimit" end);
        "\(.resource): used \(.used) of \(.hard) (\(.pct)%)"
        + (if .pct >= 100 and .resource == "pods" then " - new pods, including rolling-update surge pods, will be rejected" else "" end)) ),
  ( $ns_a[0][] | select(.containers_without_requests > 0)
    | f("info"; "resources"; "namespace"; .namespace; "namespace/" + .namespace; "NoResourceRequests";
        "\(.containers_without_requests) running container(s) have neither CPU nor memory requests (BestEffort: invisible to the scheduler, evicted first)") ),

  # --------------------------------------------------------------- services
  ( ((($eps[0].items // []) | map(select(.metadata.labels["kubernetes.io/service-name"] != null))
      | group_by(.metadata.namespace + "/" + .metadata.labels["kubernetes.io/service-name"])
      | map({key: (.[0].metadata.namespace + "/" + .[0].metadata.labels["kubernetes.io/service-name"]),
             value: ([.[].endpoints[]? | select(.conditions.ready != false)] | length)}) | from_entries)) as $ready
    | $svcs[0].items[]?
    | select(.spec.type != "ExternalName" and ((.spec.selector // {}) | length) > 0)
    | select(($ready[.metadata.namespace + "/" + .metadata.name] // 0) == 0)
    | f("warning"; "network"; "workload"; .metadata.namespace; "service/" + .metadata.name; "ServiceNoReadyEndpoints";
        "selector \(.spec.selector | kv) matches no ready pod - connections to this service fail") ),

  # ----------------------------------------------------------------- events
  ( $events[0].groups[] | select(.type == "Warning")
    | f(if .category | IN("timeout", "oom", "node", "storage", "network") then "warning" else "info" end;
        .category; "event"; .namespace; "\(.kind | ascii_downcase)/\(.name)"; .reason;
        "x\(.count) (last \(.last_seen)): \(.message)") ),

  # -------------------------------------------------------------- collector
  ( [$calls[0][] | select(.status == "ok" and (.notes | test("recovered-after")))]
    | if length > 0 then f("warning"; "network"; "collector"; ""; "k8s-perf-collector"; "APIConnectionRetries";
        "\(length) call(s) succeeded only after client-go retried failed connections (flaky network path to the API server): \(map(.id) | .[0:6] | join(", "))")
      else empty end ),
  ( [$calls[0][] | select(.phase != "probe" and .status != "ok")] | group_by(.status)[]
    | .[0].status as $s
    | f(if $s | IN("forbidden", "unauthorized", "not_found") then "info" else "warning" end;
        (if $s == "timeout" then "timeout" else "collector" end); "collector"; ""; "k8s-perf-collector";
        ({"timeout": "CollectorTimeouts", "forbidden": "CollectorForbidden", "unauthorized": "CollectorUnauthorized",
          "not_found": "CollectorNotFound", "throttled": "CollectorThrottled", "unreachable": "CollectorUnreachable",
          "server_error": "CollectorServerErrors"}[$s] // "CollectorErrors");
        "\(length) call(s): \(map(.id) | .[0:6] | join(", "))\(if length > 6 then ", ..." else "" end) - \(.[0].message | trunc(200))") )
]
| sort_by([(.severity | sevrank), .category, .namespace, .object, .reason])
JQ

define JQ_SUMMARY <<'JQ'
def sev($s): map(select(.severity == $s)) | length;
def stat($id): ([$calls[0][] | select(.id == $id) | .status] | .[0] // "not-collected");
def node_stat($kind): [$calls[0][] | select(.phase == "node" and (.id | endswith(":" + $kind)))]
  | if length == 0 then "not-collected" else "\(map(select(.status == "ok")) | length)/\(length) nodes ok" end;
$failures[0] as $F
| ($F | sev("critical")) as $crit | ($F | sev("warning")) as $warn
| $containers[0] as $C
| {
    collector: $run[0],
    cluster: {
      context: ($run[0].context // ""),
      server_version: ($version[0].gitVersion // $api[0].version // null),
      platform: ($version[0].platform // null),
      nodes: ($nodes_a[0] | length), namespaces: ($ns_a[0] | length),
      pods: ($pods[0].items | length), containers: ($C | length)
    },
    verdict: {
      status: (if $crit > 0 then "CRITICAL" elif $warn > 0 then "WARNING" else "OK" end),
      critical: $crit, warning: $warn, info: ($F | sev("info")),
      by_category: ($F | group_by(.category)
                    | map({category: .[0].category, critical: sev("critical"), warning: sev("warning"), info: sev("info")})
                    | sort_by(-.critical, -.warning, -.info))
    },
    api: {
      health: {
        livez: stat("livez"), readyz: stat("readyz"),
        failed_checks: ([$livez, $readyz] | map([scan("\\[-\\]([^\\[\\n\\\\\"]+)") | .[0]]) | add)
      },
      client_latency: $client[0],
      server: $api[0]
    },
    nodes: $nodes_a[0],
    namespaces: $ns_a[0],
    containers: {
      total: ($C | length),
      running: ($C | map(select(.state == "running")) | length),
      not_ready: ($C | map(select(.type == "app" and .pod_phase == "Running" and (.ready | not))) | length),
      restarts: ($C | map(.restarts) | add // 0),
      with_usage: ($C | map(select(.cpu_usage_m != null)) | length),
      top_cpu: ($C | map(select(.cpu_usage_m != null)) | sort_by(-.cpu_usage_m) | .[0:10]),
      top_memory: ($C | map(select(.mem_working_set_mib != null)) | sort_by(-.mem_working_set_mib) | .[0:10]),
      top_throttled: ($C | map(select((.cpu_throttled_pct // 0) > 0)) | sort_by(-.cpu_throttled_pct) | .[0:10]),
      top_restarts: ($C | map(select(.restarts > 0)) | sort_by(-.restarts) | .[0:10]),
      unhealthy: ($C | map(select(.reason != "" and (.reason | IN("Completed") | not)) | select(.pod_phase != "Succeeded")) | .[0:25])
    },
    events: ($events[0] | del(.groups) + {recent_warnings: ([.groups[] | select(.type == "Warning")] | .[0:25]),
                                          timeouts: [.groups[] | select(.category == "timeout")]}),
    failures: $F,
    data_sources: {
      apiserver_metrics: {start: stat("metrics:apiserver:start"), end: stat("metrics:apiserver:end"), mode: $api[0].mode},
      kubelet_summary: node_stat("summary"), cadvisor: node_stat("cadvisor"),
      prober_metrics: node_stat("probes"), kubelet_metrics: node_stat("kubelet"),
      metrics_server: ([$calls[0][] | select(.id | startswith("metrics:metrics-server")) | .status] | .[0] // "not-collected"),
      object_lists: ([$calls[0][] | select(.phase == "objects" or .phase == "cluster")] | map({key: .id, value: .status}) | from_entries)
    },
    collector_calls: {
      total: ($calls[0] | length),
      by_status: ($calls[0] | group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
      by_phase: ($calls[0] | group_by(.phase) | map({phase: .[0].phase, calls: length,
                  failed: (map(select(.status != "ok")) | length),
                  wall_ms: (map(.wall_ms // 0) | add), http_ms: (map(.http_ms // 0) | add)})),
      slowest: ($calls[0] | sort_by(-(.http_ms // .wall_ms // 0)) | .[0:10]
                | map({id, status, http_ms, wall_ms, bytes}))
    }
  }
JQ

define JQ_REPORT <<'JQ'
def md: if . == null or . == "" then "-" else tostring | one_line | gsub("\\|"; "\\|") end;
def row: map(md) | "| " + join(" | ") + " |";
def table($h; $rows): if ($rows | length) == 0 then "_none_\n" else ([($h | row), ($h | map("---") | row)] + ($rows | map(row)) | join("\n")) + "\n" end;
def ratio($a; $b): "\($a | md) / \($b | md)";
def more($all; $shown; $file): if ($all | length) > $shown then "_... \(($all | length) - $shown) more in \($file)_\n" else "" end;
. as $s
| $s.api.server as $a
| [
  "# Kubernetes performance and failure report", "",
  "| | |", "|---|---|",
  "| Cluster context | \($s.cluster.context | md) |",
  "| Kubernetes version | \($s.cluster.server_version | md) (\($s.cluster.platform | md)) |",
  "| Collected | \($s.collector.started_at | md) to \($s.collector.finished_at | md) (\($s.collector.duration_s | md)s) |",
  "| Scope | \(if $s.collector.scope.all_namespaces then "all namespaces" else ($s.collector.scope.namespaces | join(", ")) end) |",
  "| API server metrics | \(if $a.mode == "window" then "counter deltas over a \($a.window_s)s observation window" elif $a.mode == "cumulative" then "cumulative since kube-apiserver start (\($a.seconds_covered)s)" else "unavailable" end) |",
  "| Inventory | \($s.cluster.nodes) nodes, \($s.cluster.namespaces) namespaces, \($s.cluster.pods) pods, \($s.cluster.containers) containers |",
  "| Collector | k8s-perf-collector \($s.collector.version | md), \($s.collector_calls.total) API calls |",
  "",
  "## Verdict: \($s.verdict.status)", "",
  "**\($s.verdict.critical) critical**, **\($s.verdict.warning) warning** and \($s.verdict.info) informational findings.", "",
  table(["Category", "Critical", "Warning", "Info"]; [$s.verdict.by_category[] | [.category, .critical, .warning, .info]]),
  "### Critical and warning findings", "",
  ([$s.failures[] | select(.severity != "info")] as $cw
   | table(["Severity", "Category", "Namespace", "Object", "Reason", "Message"];
           [$cw[0:60][] | [.severity, .category, .namespace, .object, .reason, (.message | trunc(240))]])
     + more($cw; 60; "csv/failures.csv")),
  "Informational findings are listed in `csv/failures.csv`.", "",

  "## Kubernetes API", "",
  "### Health endpoints", "",
  "- `/livez`: \($s.api.health.livez) - `/readyz`: \($s.api.health.readyz)\(if ($s.api.health.failed_checks | length) > 0 then " - failing checks: " + ($s.api.health.failed_checks | join(", ")) else " - all checks passing" end)", "",
  "### Client-side latency", "",
  "Measured by this collector: HTTP round trip reported by client-go (`kubectl -v=6`). *Avg wall* adds kubectl process start-up.", "",
  table(["Endpoint", "Path", "Samples", "OK", "Timeouts", "Errors", "p50 ms", "p90 ms", "p99 ms", "Max ms", "Avg wall ms"];
        [$s.api.client_latency[] | [.endpoint, .path, .samples, .ok, .timeouts, (.errors + .forbidden), .p50_ms, .p90_ms, .p99_ms, .max_ms, .avg_wall_ms]]),
  "### Server-side (kube-apiserver /metrics)", "",
  (if $a.available | not then "_kube-apiserver /metrics was not available._\n" else
   ([
    "| Metric | Value |", "|---|---|",
    "| Requests | \($a.requests.total) (\($a.requests.per_second | md)/s) over \($a.seconds_covered | md)s |",
    "| 5xx / 429 / 401+403 / 409 | \($a.requests.code_5xx) / \($a.requests.code_429) / \($a.requests.code_401_403) / \($a.requests.code_409) |",
    "| Requests terminated / aborted | \($a.terminations | map(.count) | add // 0) / \($a.aborts | map(.count) | add // 0) |",
    "| APF rejected | \($a.apf.rejected | map(.count) | add // 0) |",
    "| In-flight (read-only / mutating) | \($a.inflight.readOnly | md) / \($a.inflight.mutating | md) |",
    "| Long-running requests (watches) | \($a.long_running) |",
    "| Watch events/s | \($a.watch_events_per_second | md) |",
    (($a.latency_by_class[]) | "| Latency \(.class) p50 / p90 / p99 | \(.p50_ms | md) / \(.p90_ms | md) / \(.p99_ms | md) ms (n=\(.count)) |"),
    "| Process RSS / CPU / goroutines | \($a.process.resident_memory_mib | md) MiB / \($a.process.cpu_cores | md) cores / \($a.process.goroutines | md) |",
    "| Uptime | \($a.process.uptime_s | md)s |"
   ] | join("\n")) + "\n\n"
   + "#### Request latency by verb and resource (top 15 by p99)\n\n"
   + "Upstream SLOs: p99 <= 1s for mutating and single-object reads, <= 5s namespace LIST, <= 30s cluster LIST. Histogram quantiles are interpolated within buckets.\n\n"
   + table(["Verb", "Resource", "Scope", "Requests", "p50 ms", "p90 ms", "p99 ms", "SLO ms", "Breach"];
           [$a.latency[0:15][] | [.verb, .resource, .scope, .count, .p50_ms, .p90_ms, .p99_ms, .slo_ms, (if .slo_breach then "YES" else "no" end)]])
   + "\n#### Errors, timeouts and throttling\n\n"
   + table(["Verb", "Resource", "Code", "Count"]; [$a.error_series[0:15][] | [.verb, .resource, .code, .count]])
   + (if ($a.terminations | length) > 0 then "\nTerminated requests:\n\n" + table(["Verb", "Resource", "Code", "Count"]; [$a.terminations[] | [.verb, .resource, .code, .count]]) else "" end)
   + (if ($a.apf.rejected | length) > 0 then "\nAPF rejections:\n\n" + table(["Priority level", "Flow schema", "Reason", "Count"]; [$a.apf.rejected[] | [.priority_level, .flow_schema, .reason, .count]]) else "" end)
   + "\n#### etcd (as seen by kube-apiserver)\n\n"
   + table(["Operation", "Requests", "p50 ms", "p90 ms", "p99 ms"]; [$a.etcd.by_operation[] | [.operation, .count, .p50_ms, .p90_ms, .p99_ms]])
   + (if ($a.webhooks.latency | length) > 0 then "\n#### Admission webhooks\n\n" + table(["Webhook", "Type", "Operation", "Requests", "p99 ms"]; [$a.webhooks.latency[] | [.name, .type, .operation, .count, .p99_ms]]) else "" end)
   + "\n#### Largest object counts\n\n"
   + table(["Resource", "Objects"]; [$a.objects[0:10][] | [.resource, .count]])
   end),

  "## Nodes", "",
  table(["Node", "Roles", "Ready", "Pods", "CPU use/alloc m", "CPU req %", "CPU lim %", "Mem use/alloc Mi", "Mem req %", "Mem lim %", "Disk %", "PIDs %", "Kubelet"];
        [$s.nodes[] | [.node, .roles, .ready, .pods, ratio(.cpu_usage_m; .cpu_allocatable_m), .cpu_requests_pct, .cpu_limits_pct,
                        ratio(.mem_working_set_mib; .mem_allocatable_mib), .mem_requests_pct, .mem_limits_pct, .fs_used_pct, .pid_pct, .kubelet_version]]),
  "### Kubelet health", "",
  table(["Node", "PLEG relist p99 ms", "Pod start p99 ms", "Slowest runtime op (p99 ms)", "Runtime errors", "Evictions", "Stats endpoints"];
        [$s.nodes[] | [.node, .kubelet.pleg_relist.p99_ms, .kubelet.pod_start.p99_ms,
                        ((.kubelet.runtime_latency // [])[0] | if . == null then null else "\(.operation) (\(.p99_ms))" end),
                        ((.kubelet.runtime_errors // []) | map(.count) | add // 0),
                        ((.kubelet.evictions // []) | map(.count) | add // 0),
                        (.stats | to_entries | map("\(.key)=\(.value)") | join(" "))]]),

  "## Namespaces", "",
  table(["Namespace", "Pods run/pend/fail/done", "Containers", "Not ready", "Restarts", "CPU use/req m", "Mem use/req Mi", "No requests", "Warning events", "Quota max %"];
        [$s.namespaces[] | [.namespace, "\(.running)/\(.pending)/\(.failed)/\(.succeeded)", .containers, .containers_not_ready, .restarts,
                             ratio(.cpu_usage_m; .cpu_requests_m), ratio(.mem_usage_mib; .mem_requests_mib), .containers_without_requests,
                             .warning_events, .quota_max_pct]]),

  "## Containers", "",
  "\($s.containers.total) containers, \($s.containers.running) running, \($s.containers.not_ready) not ready, \($s.containers.restarts) restarts in total; usage known for \($s.containers.with_usage).", "",
  "### Unhealthy containers", "",
  table(["Namespace", "Pod", "Container", "State", "Reason", "Restarts", "Last termination", "Message"];
        [$s.containers.unhealthy[] | [.namespace, .pod, .container, .state, .reason, .restarts,
                                       (if .last_reason != "" then "\(.last_reason) exit=\(.last_exit_code)" else "" end), (.message | trunc(120))]]),
  "### Top CPU", "",
  table(["Namespace", "Pod", "Container", "CPU m", "Request m", "Limit m", "% of limit", "Throttled %"];
        [$s.containers.top_cpu[] | [.namespace, .pod, .container, .cpu_usage_m, .cpu_request_m, .cpu_limit_m, .cpu_pct_of_limit, .cpu_throttled_pct]]),
  "### Top memory", "",
  table(["Namespace", "Pod", "Container", "Working set Mi", "Request Mi", "Limit Mi", "% of limit", "OOM events"];
        [$s.containers.top_memory[] | [.namespace, .pod, .container, .mem_working_set_mib, .mem_request_mib, .mem_limit_mib, .mem_pct_of_limit, .oom_events]]),
  "### CPU throttling (CFS, since container start)", "",
  table(["Namespace", "Pod", "Container", "Throttled %", "Throttled s", "Limit m", "Usage m"];
        [$s.containers.top_throttled[] | [.namespace, .pod, .container, .cpu_throttled_pct, .cpu_throttled_seconds, .cpu_limit_m, .cpu_usage_m]]),
  "### Most restarts", "",
  table(["Namespace", "Pod", "Container", "Restarts", "Last reason", "Exit code", "Finished", "Message"];
        [$s.containers.top_restarts[] | [.namespace, .pod, .container, .restarts, .last_reason, .last_exit_code, .last_finished, (.last_message | trunc(100))]]),

  "## Events", "",
  "\($s.events.total) events (\($s.events.warning) warning occurrences).", "",
  "### Warning events by reason", "",
  table(["Reason", "Category", "Occurrences", "Objects", "Example message"];
        [$s.events.by_reason[0:20][] | [.reason, .category, .count, .objects, .example]]),
  "### Timeouts", "",
  table(["Namespace", "Object", "Reason", "Count", "Last seen", "Message"];
        [$s.events.timeouts[0:15][] | [.namespace, "\(.kind)/\(.name)", .reason, .count, .last_seen, (.message | trunc(160))]]),
  "### Most recent warning events", "",
  table(["Last seen", "Namespace", "Object", "Reason", "Count", "Message"];
        [$s.events.recent_warnings[0:20][] | [.last_seen, .namespace, "\(.kind)/\(.name)", .reason, .count, (.message | trunc(160))]]),

  "## Data sources and collector run", "",
  table(["Source", "Status"];
        [["kube-apiserver /metrics", "start=\($s.data_sources.apiserver_metrics.start), end=\($s.data_sources.apiserver_metrics.end), mode=\($s.data_sources.apiserver_metrics.mode)"],
         ["kubelet Summary API", $s.data_sources.kubelet_summary], ["cAdvisor", $s.data_sources.cadvisor],
         ["kubelet prober metrics", $s.data_sources.prober_metrics], ["kubelet metrics", $s.data_sources.kubelet_metrics],
         ["metrics-server", $s.data_sources.metrics_server]]),
  table(["Phase", "Calls", "Failed", "Total HTTP ms", "Total wall ms"];
        [$s.collector_calls.by_phase[] | [.phase, .calls, .failed, .http_ms, .wall_ms]]),
  "Calls by outcome: \($s.collector_calls.by_status | to_entries | map("\(.key)=\(.value)") | join(", ")). Every call is listed in `csv/collector_calls.csv`; timeouts and errors are also in `collector.log`.", "",
  "---", "_Generated by k8s-perf-collector \($s.collector.version). Raw responses are in `raw/`, tables in `csv/`._"
] | join("\n")
JQ

analyze() {
  local dir=${1%/}
  local A="$dir/analysis" R="$dir/raw"
  [[ -d $R ]] || die 1 "$dir does not look like a k8s-perf-collector output directory (no raw/)"
  mkdir -p "$A/nodes" "$dir/csv"
  [[ -n $LOG_FILE ]] || LOG_FILE="$dir/collector.log"
  log_info "analysing $dir"

  local run now window timeout th
  run=$(json_or "$dir/meta/run.json" '{}')
  now=$(jq -r '.finished_epoch // empty' "$run")
  [[ $now =~ ^[0-9]+$ ]] || now=$(date +%s)
  window=$(jq -r '.window_actual_s // .window_s // 0' "$run")
  timeout=$(jq -r '.request_timeout_s // 15' "$run")
  th=$(thresholds_json)

  local empty_list='{"items":[]}'
  prom_json() {
    if [[ -s $1.gz ]]; then gzip -dc "$1.gz" | jq -R -n "$JQ_LIB [inputs | parse_prom]"
    elif [[ -s $1 ]]; then jq -R -n "$JQ_LIB [inputs | parse_prom]" "$1"
    else echo '[]'; fi
  }
  obj() { json_or "$R/objects/$1.json" "$empty_list"; }

  if [[ -f $dir/meta/calls.tsv ]]; then
    jq -R -s "$JQ_CALLS" "$dir/meta/calls.tsv" >"$A/calls.json"
  else
    echo '[]' >"$A/calls.json"
  fi

  jq -n "$JQ_LIB$JQ_APISERVER" --argjson window "$window" --argjson now "$now" \
    --slurpfile start <(prom_json "$R/metrics/apiserver-start.prom") \
    --slurpfile end <(prom_json "$R/metrics/apiserver-end.prom") >"$A/apiserver.json" ||
    die 1 "analysis failed: API server metrics"

  local d node
  rm -f "$A"/nodes/*.json
  shopt -s nullglob
  for d in "$R"/nodes/*/; do
    # A node whose every kubelet call failed leaves an empty directory (which
    # git does not keep); treat it exactly like a missing one.
    [[ -n $(ls -A "$d") ]] || continue
    node=$(basename "$d")
    jq -n "$JQ_LIB$JQ_NODE_STATS" --arg node "$node" \
      --slurpfile summary "$(json_or "$d/summary.json" null)" \
      --slurpfile cad <(prom_json "$d/cadvisor.prom") \
      --slurpfile prb <(prom_json "$d/probes.prom") \
      --slurpfile kub <(prom_json "$d/kubelet.prom") >"$A/nodes/$node.json" ||
      log_warn "analysis of node $node failed"
  done
  local -a node_files=("$A"/nodes/*.json)
  shopt -u nullglob
  if ((${#node_files[@]})); then jq -s . "${node_files[@]}" >"$A/node-stats.json"; else echo '[]' >"$A/node-stats.json"; fi

  jq -n "$JQ_LIB$JQ_CONTAINERS" --slurpfile pods "$(obj pods)" --slurpfile nstats "$A/node-stats.json" \
    --slurpfile ms "$(json_or "$R/metrics/metrics-server-pods.json" "$empty_list")" >"$A/containers.json" ||
    die 1 "analysis failed: containers"

  jq -n "$JQ_LIB$JQ_NODES" --slurpfile nodes "$(json_or "$R/cluster/nodes.json" "$empty_list")" \
    --slurpfile nstats "$A/node-stats.json" --slurpfile pods "$(obj pods)" --slurpfile calls "$A/calls.json" \
    >"$A/nodes.json" || die 1 "analysis failed: nodes"

  jq -n "$JQ_LIB$JQ_EVENTS" --slurpfile ev "$(obj events)" >"$A/events.json" || die 1 "analysis failed: events"

  local scope
  scope=$(jq -c '.scope.namespaces // []' "$run")
  jq -n "$JQ_LIB$JQ_NAMESPACES" --slurpfile containers "$A/containers.json" --slurpfile pods "$(obj pods)" \
    --slurpfile quotas "$(obj resourcequotas)" --slurpfile events "$A/events.json" \
    --slurpfile nslist "$(json_or "$R/cluster/namespaces.json" "$empty_list")" --argjson scope "$scope" \
    >"$A/namespaces.json" || die 1 "analysis failed: namespaces"

  jq -n "$JQ_LIB$JQ_API_CLIENT" --slurpfile calls "$A/calls.json" >"$A/api-client.json" ||
    die 1 "analysis failed: client latency"

  jq -n "$JQ_LIB$JQ_FAILURES" \
    --slurpfile calls "$A/calls.json" --slurpfile client "$A/api-client.json" --slurpfile api "$A/apiserver.json" \
    --slurpfile nodes_a "$A/nodes.json" --slurpfile containers "$A/containers.json" --slurpfile pods "$(obj pods)" \
    --slurpfile deploy "$(obj deployments)" --slurpfile sts "$(obj statefulsets)" --slurpfile ds "$(obj daemonsets)" \
    --slurpfile jobs "$(obj jobs)" --slurpfile hpas "$(obj hpas)" --slurpfile pvcs "$(obj pvcs)" \
    --slurpfile svcs "$(obj services)" --slurpfile eps "$(obj endpointslices)" \
    --slurpfile events "$A/events.json" --slurpfile ns_a "$A/namespaces.json" --slurpfile nstats "$A/node-stats.json" \
    --rawfile livez "$(text_or_empty "$R/cluster/livez.txt")" --rawfile readyz "$(text_or_empty "$R/cluster/readyz.txt")" \
    --argjson th "$th" --argjson now "$now" --argjson timeout "$timeout" >"$A/failures.json" ||
    die 1 "analysis failed: failure detection"

  jq -n "$JQ_LIB$JQ_SUMMARY" \
    --slurpfile run "$run" --slurpfile version "$(json_or "$R/cluster/version.json" '{}')" \
    --slurpfile failures "$A/failures.json" --slurpfile containers "$A/containers.json" \
    --slurpfile nodes_a "$A/nodes.json" --slurpfile ns_a "$A/namespaces.json" --slurpfile pods "$(obj pods)" \
    --slurpfile client "$A/api-client.json" --slurpfile api "$A/apiserver.json" --slurpfile events "$A/events.json" \
    --slurpfile calls "$A/calls.json" \
    --rawfile livez "$(text_or_empty "$R/cluster/livez.txt")" --rawfile readyz "$(text_or_empty "$R/cluster/readyz.txt")" \
    >"$dir/summary.json" || die 1 "analysis failed: summary"

  write_csvs "$dir"
  jq -r "$JQ_LIB$JQ_REPORT" "$dir/summary.json" >"$dir/report.md" || die 1 "analysis failed: report"
  log_info "analysis written: $dir/report.md, $dir/summary.json, $dir/csv/"
}

write_csvs() {
  local dir=$1 A="$1/analysis" C="$1/csv"
  jq -r "$JQ_LIB"'
    map(. + {liveness_failures: .probe_failures.liveness, readiness_failures: .probe_failures.readiness,
             startup_failures: .probe_failures.startup})
    | to_csv(["namespace","pod","container","type","node","owner","pod_phase","qos","ready","state","reason","exit_code",
              "restarts","last_reason","last_exit_code","last_finished","cpu_usage_m","cpu_request_m","cpu_limit_m",
              "cpu_pct_of_request","cpu_pct_of_limit","cpu_throttled_pct","cpu_throttled_seconds","mem_working_set_mib",
              "mem_rss_mib","mem_request_mib","mem_limit_mib","mem_pct_of_request","mem_pct_of_limit","rootfs_mib","logs_mib",
              "oom_events","liveness_failures","readiness_failures","startup_failures","usage_source","image","message","last_message"])' \
    "$A/containers.json" >"$C/containers.csv"
  jq -r "$JQ_LIB"'
    map(. + {quotas: (.quotas | map("\(.quota):\(.resource)=\(.used)/\(.hard)") | join(" "))})
    | to_csv(["namespace","pods","running","pending","failed","succeeded","unknown","containers","containers_not_ready",
              "restarts","cpu_usage_m","cpu_requests_m","cpu_limits_m","cpu_pct_of_requests","mem_usage_mib",
              "mem_requests_mib","mem_limits_mib","mem_pct_of_requests","containers_without_requests","warning_events",
              "quota_max_pct","quotas"])' "$A/namespaces.json" >"$C/namespaces.csv"
  jq -r "$JQ_LIB"'
    map(. + {conditions: (.conditions | map("\(.type)=\(.status)") | join(" ")),
             pleg_p99_ms: .kubelet.pleg_relist.p99_ms, pod_start_p99_ms: .kubelet.pod_start.p99_ms,
             runtime_errors: ((.kubelet.runtime_errors // []) | map(.count) | add // 0),
             evictions: ((.kubelet.evictions // []) | map(.count) | add // 0),
             stats: (.stats | to_entries | map("\(.key)=\(.value)") | join(" "))})
    | to_csv(["node","roles","ready","conditions","unschedulable","kubelet_version","container_runtime","os_image","kernel",
              "pods","pods_allocatable","cpu_allocatable_m","cpu_requests_m","cpu_requests_pct","cpu_limits_m",
              "cpu_limits_pct","cpu_usage_m","cpu_usage_pct","mem_allocatable_mib","mem_requests_mib","mem_requests_pct",
              "mem_limits_mib","mem_limits_pct","mem_working_set_mib","mem_usage_pct","fs_used_pct","imagefs_used_pct",
              "pids_running","pids_max","pid_pct","net_rx_errors","net_tx_errors","pleg_p99_ms","pod_start_p99_ms",
              "runtime_errors","evictions","stats"])' "$A/nodes.json" >"$C/nodes.csv"
  jq -r "$JQ_LIB"'
    map(. + {failures: (.failures | map("\(.status) x\(.count)") | join(" "))})
    | to_csv(["endpoint","path","samples","ok","timeouts","errors","forbidden","min_ms","p50_ms","p90_ms","p99_ms",
              "max_ms","avg_ms","avg_wall_ms","failures"])' "$A/api-client.json" >"$C/api_client_latency.csv"
  jq -r "$JQ_LIB"'.latency | to_csv(["verb","resource","scope","count","p50_ms","p90_ms","p99_ms","slo_ms","slo_breach"])' \
    "$A/apiserver.json" >"$C/apiserver_latency.csv"
  jq -r "$JQ_LIB"'
    ([.error_series[] | . + {kind: "response"}]
     + [.terminations[] | . + {kind: "terminated"}]
     + [.aborts[] | . + {kind: "aborted", code: ""}]
     + [.apf.rejected[] | {kind: "apf-rejected", verb: "", resource: "\(.priority_level)/\(.flow_schema)", code: .reason, count}])
    | to_csv(["kind","verb","resource","code","count"])' "$A/apiserver.json" >"$C/apiserver_errors.csv"
  jq -r "$JQ_LIB"'.groups | to_csv(["last_seen","first_seen","namespace","kind","name","type","reason","category","count","source","host","message"])' \
    "$A/events.json" >"$C/events.csv"
  jq -r "$JQ_LIB"'to_csv(["severity","category","scope","namespace","object","reason","message"])' \
    "$A/failures.json" >"$C/failures.csv"
  jq -r "$JQ_LIB"'to_csv(["ts","phase","id","target","status","exit_code","wall_ms","http_ms","http_requests","http_status","bytes","notes","message"])' \
    "$A/calls.json" >"$C/collector_calls.csv"
}

# ---------------------------------------------------------------------- main --
# shellcheck disable=SC2329 # EXIT trap handler
cleanup() {
  local rc=$?
  local -a pids
  mapfile -t pids < <(jobs -p 2>/dev/null)
  ((${#pids[@]})) && kill "${pids[@]}" 2>/dev/null
  cleanup_write_probe
  [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf "$TMP_DIR"
  find "${RAW:-/nonexistent}" -name '*.part' -delete 2>/dev/null
  return "$rc"
}

print_verdict() {
  local dir=$1
  jq -r --arg dir "$dir" '
    "",
    "Verdict: \(.verdict.status) - \(.verdict.critical) critical, \(.verdict.warning) warning, \(.verdict.info) info",
    (.failures | map(select(.severity != "info")) | .[0:10][] | "  \(.severity | ascii_upcase | .[0:4])  \(.reason)  \(if .namespace != "" then .namespace + "/" else "" end)\(.object)"),
    (if (.failures | map(select(.severity != "info")) | length) > 10 then "  ... see report" else empty end),
    "",
    "Report:   \($dir)/report.md",
    "Summary:  \($dir)/summary.json",
    "Tables:   \($dir)/csv/",
    "Log:      \($dir)/collector.log"' "$dir/summary.json" >&2
}

exit_for_findings() {
  local dir=$1 crit warn
  crit=$(jq '.verdict.critical' "$dir/summary.json")
  warn=$(jq '.verdict.warning' "$dir/summary.json")
  case $FAIL_ON in
    critical) ((crit > 0)) && exit 3 ;;
    warning) ((crit + warn > 0)) && exit 3 ;;
  esac
  exit 0
}

main() {
  parse_args "$@"
  init_clock
  check_prereqs
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/k8s-perf.XXXXXX") || die 1 "cannot create a temp directory"
  trap cleanup EXIT
  trap 'log_warn "interrupted"; exit 130' INT TERM

  if [[ -n $ANALYZE_ONLY ]]; then
    analyze "$ANALYZE_ONLY"
    print_verdict "${ANALYZE_ONLY%/}"
    exit_for_findings "${ANALYZE_ONLY%/}"
  fi

  build_kubectl
  resolve_context
  STARTED_AT=$(ts_utc)
  STARTED_EPOCH=$(date +%s)
  RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  [[ -n $OUT_DIR ]] || OUT_DIR="./k8s-perf-$(printf '%s' "$CTX_NAME" | tr -c 'A-Za-z0-9._-' '_')-$RUN_ID"
  OUT_DIR=${OUT_DIR%/}
  RAW="$OUT_DIR/raw"

  if [[ -n $DRY_RUN ]]; then
    dry_run_plan
    [[ $DRY_RUN == server ]] && { preflight_server || exit $?; }
    exit 0
  fi

  [[ -e $OUT_DIR && -n $(ls -A "$OUT_DIR" 2>/dev/null) ]] && die 1 "output directory $OUT_DIR exists and is not empty"
  collect
  analyze "$OUT_DIR"
  if $ARCHIVE; then
    tar -czf "$OUT_DIR.tar.gz" -C "$(dirname "$OUT_DIR")" "$(basename "$OUT_DIR")" &&
      log_info "archive written: $OUT_DIR.tar.gz"
  fi
  print_verdict "$OUT_DIR"
  exit_for_findings "$OUT_DIR"
}

# Run main unless sourced (tests source the script to reach its functions).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
