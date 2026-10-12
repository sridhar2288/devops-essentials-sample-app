#!/usr/bin/env bash
#
# Offline tests for k8s-perf-collector.sh - no cluster needed.
#
# Covers the CLI, the client dry run, the helper functions (error
# classification, kubectl -v=6 parsing, quantity parsing, histogram
# quantiles, redaction) and the full analysis against the committed sample
# runs plus synthetic API server metrics.
#
#   k8s-perf/tests/test-offline.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
SCRIPT="$ROOT/k8s-perf-collector.sh"
SAMPLES="$ROOT/samples"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/k8s-perf-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok    %s\n' "$1"; }
not_ok() {
  failed=$((failed + 1))
  printf 'FAIL  %s\n' "$1"
  [[ -n ${2:-} ]] && printf '      %s\n' "$2"
  return 0
}
expect_eq() { if [[ $2 == "$3" ]]; then ok "$1"; else not_ok "$1" "expected '$3', got '$2'"; fi; }
expect_cmd() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi
}
expect_exit() {
  local name=$1 want=$2 got
  shift 2
  "$@" >/dev/null 2>&1
  got=$?
  expect_eq "$name" "$got" "$want"
}
has_finding() { # summary.json reason [object substring] [severity]
  jq -e --arg r "$2" --arg o "${3:-}" --arg s "${4:-}" \
    'any(.failures[]; .reason == $r and (.object | contains($o)) and ($s == "" or .severity == $s))' "$1" >/dev/null
}
expect_finding() { # name summary reason [object] [severity]
  local detail="no $3 finding"
  [[ -n ${4:-} ]] && detail+=" for $4"
  [[ -n ${5:-} ]] && detail+=" with severity $5"
  if has_finding "$2" "$3" "${4:-}" "${5:-}"; then ok "$1"; else not_ok "$1" "$detail"; fi
}

# --------------------------------------------------------------------- lint --
echo "# static checks"
expect_cmd "bash -n parses the script" bash -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  expect_cmd "shellcheck is clean" shellcheck -x "$SCRIPT" "$HERE/test-offline.sh"
else
  echo "skip  shellcheck not installed"
fi

# ---------------------------------------------------------------------- CLI --
echo "# command line"
expect_exit "--help exits 0" 0 "$SCRIPT" --help
expect_cmd "--help documents --dry-run" bash -c "'$SCRIPT' --help | grep -q -- '--dry-run'"
expect_cmd "--version prints the version" bash -c "'$SCRIPT' --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"
expect_exit "non-numeric --window is rejected" 1 "$SCRIPT" --window abc --dry-run
expect_exit "unknown --dry-run mode is rejected" 1 "$SCRIPT" --dry-run=maybe
expect_exit "unknown threshold is rejected" 1 "$SCRIPT" --threshold nope=1 --dry-run
expect_exit "non-numeric threshold is rejected" 1 "$SCRIPT" --threshold mem_limit_pct=high --dry-run
expect_exit "bad --fail-on is rejected" 1 "$SCRIPT" --fail-on sometimes --dry-run
expect_exit "invalid namespace name is rejected" 1 "$SCRIPT" -n Not_Valid --dry-run
expect_exit "unknown option is rejected" 1 "$SCRIPT" --frobnicate
expect_exit "--analyze-only needs an output directory" 1 "$SCRIPT" --analyze-only "$WORK/does-not-exist"

# ------------------------------------------------------------ client dry run --
echo "# client dry run (must not contact the cluster or write anything)"
cat >"$WORK/unreachable.kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: nowhere
  cluster: {server: "https://203.0.113.1:6443"}
users:
- name: nobody
  user: {token: "not-a-real-token"}
contexts:
- name: nowhere
  context: {cluster: nowhere, user: nobody}
current-context: nowhere
EOF
plan="$WORK/plan.txt"
start=$SECONDS
"$SCRIPT" --dry-run --kubeconfig "$WORK/unreachable.kubeconfig" -o "$WORK/dry-out" -n team-a,team-b \
  --probe-samples 3 --write-probe >"$plan" 2>&1
expect_eq "client dry run exits 0 against an unreachable cluster" "$?" 0
expect_cmd "client dry run returns quickly (no network waits)" test $((SECONDS - start)) -lt 20
expect_cmd "client dry run writes no output directory" test ! -e "$WORK/dry-out"
for want in "get --raw /version" "get --raw /metrics" "/proxy/stats/summary" "/proxy/metrics/cadvisor" \
  "/proxy/metrics/probes" "get pods -n team-a -o json" "get events -n team-b -o json" \
  "create --validate=false" "Planned kubectl invocations" "context.*nowhere"; do
  expect_cmd "plan mentions: $want" grep -Eq -- "$want" "$plan"
done

# ---------------------------------------------------------- unit: helpers --
echo "# helper functions"
# shellcheck source=SCRIPTDIR/../k8s-perf-collector.sh
source "$SCRIPT"
classify() { classify_call "$@"; }
expect_eq "classify: success" "$(classify 0 200 "")" ok
expect_eq "classify: HTTP 403" "$(classify 1 403 "Error from server (Forbidden): ...")" forbidden
expect_eq "classify: HTTP 404" "$(classify 1 404 "")" not_found
expect_eq "classify: HTTP 429" "$(classify 1 429 "")" throttled
expect_eq "classify: HTTP 503" "$(classify 1 503 "Error from server (ServiceUnavailable): error trying to reach service: dial tcp 172.18.0.2:10250: connect: connection refused")" server_error
expect_eq "classify: HTTP 504" "$(classify 1 504 "")" timeout
expect_eq "classify: timeout(1) killed kubectl" "$(classify 124 "" "")" timeout
expect_eq "classify: client timeout" "$(classify 1 "" "Unable to connect to the server: context deadline exceeded (Client.Timeout exceeded while awaiting headers)")" timeout
expect_eq "classify: TLS handshake timeout" "$(classify 1 "" "Unable to connect to the server: net/http: TLS handshake timeout")" timeout
expect_eq "classify: connection reset" "$(classify 1 "" "Unable to connect to the server: read tcp 127.0.0.1:1->127.0.0.1:2: read: connection reset by peer")" unreachable
expect_eq "classify: no kubeconfig (localhost:8080)" "$(classify 1 "" "The connection to the server localhost:8080 was refused - did you specify the right host or port?")" unreachable
expect_eq "classify: unknown failure" "$(classify 1 "" "something odd")" error

http() { printf '%s\n' "$@" | awk "$AWK_HTTP"; }
expect_eq "parse -v=6 structured log" \
  "$(http 'I1012 18:00:00.000000 1 round_trippers.go:632] "Response" verb="GET" url="https://x/livez" status="200 OK" milliseconds=13')" "13 1 200 0"
expect_eq "parse -v=6 legacy log" \
  "$(http 'I1012 18:00:00.000000 1 round_trippers.go:553] GET https://x/livez 403 Forbidden in 7 milliseconds')" "7 1 403 0"
expect_eq "parse -v=6 retried request" \
  "$(http '"Response" verb="GET" url="https://x" status="" milliseconds=1' '"Response" verb="GET" url="https://x" status="200 OK" milliseconds=9')" "10 2 200 1"
expect_eq "parse -v=6 without responses" "$(http 'error: something')" "- 0 - 0"

jqlib() { jq -nr "$JQ_LIB $1"; }
expect_eq "cpu: 250m" "$(jqlib '"250m" | cpu_m')" 250
expect_eq "cpu: 2 cores" "$(jqlib '"2" | cpu_m')" 2000
expect_eq "cpu: 1500u" "$(jqlib '"1500u" | cpu_m')" 1.5
expect_eq "cpu: 2500000n" "$(jqlib '"2500000n" | cpu_m')" 2.5
expect_eq "bytes: 64Mi" "$(jqlib '"64Mi" | bytes')" 67108864
expect_eq "bytes: 1Gi" "$(jqlib '"1Gi" | bytes')" 1073741824
expect_eq "bytes: 500k" "$(jqlib '"500k" | bytes')" 500000
expect_eq "bytes: 1e3" "$(jqlib '"1e3" | bytes')" 1000
expect_eq "bytes: plain" "$(jqlib '"128974848" | bytes')" 128974848
expect_eq "bytes: garbage" "$(jqlib '"lots" | bytes')" null
buckets='[{le: 0.1, c: 50}, {le: 0.5, c: 90}, {le: 1, c: 100}, {le: infinite, c: 100}]'
expect_eq "histogram p50" "$(jqlib "hq(0.5; $buckets)")" 0.1
expect_eq "histogram p90" "$(jqlib "hq(0.9; $buckets)")" 0.5
expect_eq "histogram p99" "$(jqlib "hq(0.99; $buckets)" | cut -c1-4)" 0.95
expect_eq "histogram empty" "$(jqlib 'hq(0.99; [{le: infinite, c: 0}])')" null
expect_eq "histogram +Inf bucket" "$(jqlib 'hq(0.99; [{le: 1, c: 1}, {le: infinite, c: 10}])')" 1
expect_eq "prometheus line parsing" \
  "$(printf '%s\n' 'apiserver_request_total{code="200",verb="LIST",resource="pods"} 42' | jq -R -c "$JQ_LIB parse_prom | [.n, .l.verb, .l.code, .v]")" \
  '["apiserver_request_total","LIST","200",42]'
expect_eq "nearest-rank percentile" "$(jqlib '[5,1,4,2,3,9,8,7,6,10] | nearest(0.9)')" 9

cat >"$WORK/pods.json" <<'EOF'
{"items": [{"metadata": {"name": "p", "managedFields": [{"manager": "kubectl"}],
  "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{...}", "keep": "me"}},
  "spec": {"containers": [{"name": "c", "env": [{"name": "PASSWORD", "value": "hunter2"},
  {"name": "FROM_SECRET", "valueFrom": {"secretKeyRef": {"name": "s", "key": "k"}}}]}]}}]}
EOF
REDACT=true redact_json "$WORK/pods.json"
expect_eq "redaction: env values" "$(jq -r '.items[0].spec.containers[0].env[0].value' "$WORK/pods.json")" "<redacted>"
expect_eq "redaction: valueFrom kept" "$(jq -r '.items[0].spec.containers[0].env[1].valueFrom.secretKeyRef.name' "$WORK/pods.json")" s
expect_eq "redaction: managedFields" "$(jq -r '.items[0].metadata.managedFields' "$WORK/pods.json")" null
expect_eq "redaction: last-applied annotation" "$(jq -r '.items[0].metadata.annotations | keys | join(",")' "$WORK/pods.json")" keep

# ------------------------------------------------- analysis: sample runs --
analyze_copy() { # sample name -> prints the copy's path
  local dst="$WORK/$1"
  cp -r "$SAMPLES/$1" "$dst"
  rm -rf "$dst/analysis" "$dst/summary.json" "$dst/report.md" "$dst"/csv/*
  printf '%s\n' "$dst"
}

echo "# analysis of samples/demo-run (broken workloads + API throttling)"
demo=$(analyze_copy demo-run)
expect_exit "--analyze-only succeeds" 0 "$SCRIPT" --analyze-only "$demo"
s="$demo/summary.json"
for f in report.md summary.json csv/containers.csv csv/namespaces.csv csv/nodes.csv csv/failures.csv csv/events.csv \
  csv/api_client_latency.csv csv/apiserver_latency.csv csv/apiserver_errors.csv csv/collector_calls.csv; do
  expect_cmd "writes $f" test -s "$demo/$f"
done
expect_eq "verdict" "$(jq -r .verdict.status "$s")" CRITICAL
expect_finding "crash loop detected" "$s" CrashLoopBackOff "" critical
expect_finding "flapping crash loop detected" "$s" CrashLooping "crashloop" critical
expect_finding "OOM kill detected" "$s" OOMKilled "oom-" critical
expect_finding "image pull failure detected" "$s" ImagePullBackOff "bad-image" critical
expect_finding "missing ConfigMap detected" "$s" CreateContainerConfigError "missing-config" critical
expect_finding "unschedulable pod detected" "$s" Unschedulable "unschedulable" critical
expect_finding "stalled rollout detected" "$s" ProgressDeadlineExceeded "deployment/bad-image" critical
expect_finding "failed Job detected" "$s" BackoffLimitExceeded "job/failing-job" warning
expect_finding "pending PVC detected" "$s" PVCPending "pvc/data-pending"
expect_finding "exhausted quota detected" "$s" QuotaExhausted "web-quota"
expect_finding "CPU throttling detected" "$s" CPUThrottling "cpu-throttled-worker"
expect_finding "service without endpoints detected" "$s" ServiceNoReadyEndpoints "service/crashloop"
expect_finding "never-ready container detected" "$s" ContainerNotReady "probe-timeout"
expect_finding "liveness failures detected" "$s" LivenessProbeFailures "liveness-fail"
expect_finding "probe timeouts surfaced from events" "$s" Unhealthy "probe-timeout" warning
expect_finding "API 429s detected" "$s" APIServerThrottled429
expect_finding "APF rejections detected" "$s" APFRejectedRequests
expect_eq "healthy web pods are not flagged" \
  "$(jq '[.failures[] | select(.object | test("pod/web-"))] | map(select(.severity != "info")) | length' "$s")" 0
expect_eq "API metrics are window deltas" "$(jq -r .api.server.mode "$s")" window
expect_eq "every client probe endpoint measured" "$(jq '[.api.client_latency[] | select(.ok == .samples)] | length' "$s")" \
  "$(jq '.api.client_latency | length' "$s")"
expect_eq "write probe timed" "$(jq '[.api.client_latency[] | select(.endpoint | startswith("cm-"))] | length' "$s")" 4
expect_eq "all kubelets scraped" "$(jq -r .data_sources.kubelet_summary "$s")" "2/2 nodes ok"
expect_cmd "container usage present" jq -e '.containers.with_usage > 10' "$s"
expect_cmd "report has every section" bash -c "grep -q '^## Verdict' '$demo/report.md' && grep -q '^## Kubernetes API' '$demo/report.md' && grep -q '^## Nodes' '$demo/report.md' && grep -q '^## Namespaces' '$demo/report.md' && grep -q '^## Containers' '$demo/report.md' && grep -q '^## Events' '$demo/report.md'"
expect_eq "containers.csv header" "$(head -1 "$demo/csv/containers.csv" | cut -d, -f1-4)" '"namespace","pod","container","type"'
expect_eq "failures.csv rows match summary" "$(($(wc -l <"$demo/csv/failures.csv") - 1))" "$(jq '.failures | length' "$s")"
expect_exit "--fail-on critical exits 3" 3 "$SCRIPT" --analyze-only "$demo" --fail-on critical
expect_exit "--fail-on none exits 0" 0 "$SCRIPT" --analyze-only "$demo" --fail-on none
"$SCRIPT" --analyze-only "$demo" --threshold restart_count=1000 >/dev/null 2>&1
expect_eq "--threshold changes the analysis" \
  "$(jq '[.failures[] | select(.reason == "HighRestartCount" or .reason == "CrashLooping")] | length' "$s")" 0

echo "# analysis of samples/degraded-run (NotReady node + flaky API path)"
deg=$(analyze_copy degraded-run)
expect_exit "--analyze-only succeeds" 0 "$SCRIPT" --analyze-only "$deg"
s="$deg/summary.json"
expect_finding "NotReady node detected" "$s" NodeNotReady "node/k8s-perf-worker" critical
expect_finding "client-side API timeouts detected" "$s" APIClientTimeout "" critical
expect_finding "connection errors detected" "$s" APIClientErrors
expect_finding "kubelet unreachable via node proxy" "$s" NodeStatsUnavailable "node/k8s-perf-worker" warning
expect_finding "collector timeouts reported" "$s" CollectorTimeouts
expect_finding "silent client retries reported" "$s" APIConnectionRetries
expect_finding "DaemonSet impact detected" "$s" DaemonSetUnavailable "daemonset/kube-proxy"
expect_finding "missing API metrics explained" "$s" APIServerMetricsUnavailable
expect_cmd "timeouts are counted per endpoint" jq -e '[.api.client_latency[].timeouts] | add > 0' "$s"

# ------------------------------------------- analysis: synthetic metrics --
echo "# analysis of synthetic API server failure metrics"
syn=$(analyze_copy demo-run)
L='component="apiserver",dry_run="",group="",version="v1"'
{
  gzip -dc "$syn/raw/metrics/apiserver-end.prom.gz"
  echo "apiserver_request_total{code=\"503\",$L,resource=\"secrets\",scope=\"namespace\",subresource=\"\",verb=\"LIST\"} 42"
  echo "apiserver_request_terminations_total{code=\"504\",component=\"apiserver\",group=\"\",resource=\"secrets\",scope=\"namespace\",subresource=\"\",verb=\"LIST\",version=\"v1\"} 7"
  for le in 0.005 0.025 0.05 0.1 0.2 0.4 0.6 0.8 1 1.25 1.5 2 3 4 5 6 8 10 15 20 30 45 60 +Inf; do
    c=0
    awk -v le="$le" 'BEGIN { exit !(le == "+Inf" || le + 0 >= 3) }' && c=20
    echo "apiserver_request_duration_seconds_bucket{$L,resource=\"configmaps\",scope=\"resource\",subresource=\"\",verb=\"GET\",le=\"$le\"} $c"
    c=0
    awk -v le="$le" 'BEGIN { exit !(le == "+Inf" || le + 0 >= 0.6) }' && c=500
    echo "etcd_request_duration_seconds_bucket{group=\"\",operation=\"get\",resource=\"configmaps\",le=\"$le\"} $c"
  done
  echo 'apiserver_admission_webhook_rejection_count{error_type="calling_webhook_error",name="validate.example.com",operation="CREATE",rejection_code="400",type="validating"} 3'
} | gzip -c >"$syn/raw/metrics/apiserver-end.prom.gz.new"
mv "$syn/raw/metrics/apiserver-end.prom.gz.new" "$syn/raw/metrics/apiserver-end.prom.gz"
expect_exit "--analyze-only succeeds" 0 "$SCRIPT" --analyze-only "$syn"
s="$syn/summary.json"
expect_finding "5xx responses detected" "$s" APIServer5xx
expect_cmd "5xx count is the window delta" jq -e '[.api.server.error_series[] | select(.code == "503")][0].count == 42' "$s"
expect_finding "504 terminations detected" "$s" APIRequestsTerminated
expect_finding "latency SLO breach detected" "$s" APILatencySLOBreach "GET configmaps"
expect_cmd "SLO breach p99 is interpolated" jq -e '[.api.server.latency[] | select(.verb == "GET" and .resource == "configmaps")][0].p99_ms | . > 2000 and . <= 3000' "$s"
expect_finding "slow etcd detected" "$s" EtcdSlow "etcd/get"
expect_finding "webhook rejections reported" "$s" AdmissionWebhookRejections "validate.example.com"

echo
echo "$passed passed, $failed failed"
((failed == 0))
