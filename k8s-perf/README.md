# k8s-perf-collector

One script that captures container, namespace, node and Kubernetes API
performance measurements from any vanilla (conformant) Kubernetes cluster,
together with the messages, timeouts, errors and failure conditions behind
them. It produces a Markdown report, a JSON summary and CSV tables.

- **Nothing to install in the cluster.** It only needs `bash` (4.2+), `kubectl` and
  `jq` (1.6+) on the machine that runs it, or it can run in a pod (see [In-cluster CronJob](#in-cluster-cronjob)).
- **Vanilla APIs only.** It reads core API objects, kube-apiserver `/metrics`, `/livez`
  and `/readyz`, and each kubelet's Summary API, cAdvisor and prober metrics through the API
  server's node proxy. metrics-server and Prometheus are not required.
- **Read-only by default.** The only write it can make is the opt-in `--write-probe`,
  which creates and then deletes a ConfigMap.
- **Safe to try.** `--dry-run` prints every request without contacting the cluster;
  `--dry-run=server` also checks connectivity and RBAC.

```
k8s-perf/
├── k8s-perf-collector.sh            the collector (collect + analyze)
├── manifests/
│   ├── rbac.yaml                    least-privilege ServiceAccount and roles
│   ├── cronjob.yaml                 hourly in-cluster run, reports on a PVC
│   ├── demo-failure-scenarios.yaml  workloads that fail in 12 different ways
│   └── demo-apf-throttling.yaml     provokes real API Priority & Fairness 429s
├── samples/                         dry-run output and two full sample runs
└── tests/
    ├── test-offline.sh              123 offline tests (no cluster needed)
    └── flaky-apiserver-proxy.py     fault injector used for the degraded sample
```

## Quick start

```bash
cd k8s-perf

# 1. See exactly what would be requested. Contacts nothing, writes nothing.
./k8s-perf-collector.sh --dry-run

# 2. Check connectivity, RBAC and cluster size, still collecting nothing.
./k8s-perf-collector.sh --dry-run=server

# 3. Collect (about 30-60 s), then read the report.
./k8s-perf-collector.sh -o ./k8s-perf-report
less ./k8s-perf-report/report.md
```

Common variations:

```bash
./k8s-perf-collector.sh --context prod -n payments,checkout   # selected namespaces only
./k8s-perf-collector.sh --window 300 --probe-samples 30       # longer observation, more samples
./k8s-perf-collector.sh --write-probe --write-probe-namespace k8s-perf   # also time writes
./k8s-perf-collector.sh --threshold restart_count=10 --threshold cpu_throttle_pct=50
./k8s-perf-collector.sh --fail-on critical                    # exit 3 on critical findings (CI)
./k8s-perf-collector.sh --analyze-only ./k8s-perf-report      # re-analyze offline, new thresholds
```

Run `./k8s-perf-collector.sh --help` for every option.

## What it measures

| Level | Measurements |
|---|---|
| **Container** | state and reason, current and last exit code, restart count and last restart time, termination messages, CPU usage vs request and limit, memory working set and RSS vs request and limit, CFS throttling %, OOM events, rootfs and log usage, liveness/readiness/startup probe failures, QoS class |
| **Namespace** | pod phases, containers not ready, restarts, CPU and memory usage vs requests and limits, containers without requests, warning events, ResourceQuota usage |
| **Node** | Ready and pressure conditions, allocatable vs committed requests and limits, CPU and memory usage, node and image filesystem usage, PIDs, network errors, kubelet PLEG relist latency, pod start latency, container runtime operation latency and errors, evictions, volume operation errors |
| **Kubernetes API (client side)** | p50/p90/p99/max latency, timeouts and errors for 10 endpoints (health, discovery, single-object GET, cluster and namespace LISTs). Timing is the HTTP round trip reported by client-go, separate from kubectl start-up. Optional write path: ConfigMap create, get, patch, delete |
| **Kubernetes API (server side)** | request rate and response codes (5xx, 429, 401/403, 409), latency per verb/resource against the upstream SLOs, requests terminated or aborted (timeouts), API Priority & Fairness rejections and queue wait, in-flight and long-running requests, watch event rate, etcd latency and errors, admission webhook latency, rejections and fail-open, object counts, apiserver RSS, CPU and goroutines, TLS handshake and authentication failures |
| **Messages** | Kubernetes events, aggregated per object and reason and categorised (timeout, probe, scheduling, oom, image, crashloop, quota, storage, network, node, job, autoscaling, config, controller); container waiting and termination messages; pod and node condition messages; the error text of every failed API call |
| **Collector run** | every API call it made: wall time, HTTP time, HTTP status, bytes, retries, and an outcome classified as `ok`, `timeout`, `forbidden`, `unauthorized`, `not_found`, `throttled`, `unreachable`, `server_error` or `error` |

API server counters are scraped twice, at the start and the end of the
`--window`, and reported as deltas over that window. If the scrapes reach
different apiserver instances (HA control plane), or one scrape fails, the
counters are reported cumulative since apiserver start, and the report says so.

## Failure conditions

Every finding has a severity (`critical`, `warning`, `info`), a category, the
object, a reason and a message. They are listed in `report.md` and `csv/failures.csv`.

| Area | Reasons (severity) |
|---|---|
| API server | `APIServerHealthCheckFailed` (critical: lists failing `/livez` and `/readyz` checks), `APIClientTimeout` (critical), `APIClientErrors`, `APIClientSlow`, `APIServer5xx`, `APIServerThrottled429`, `APIRequestsTerminated`, `APIRequestsAborted`, `APFRejectedRequests`, `APFQueueWaitHigh`, `APILatencySLOBreach`, `EtcdSlow`, `EtcdRequestErrors`, `AdmissionWebhookSlow`, `AdmissionWebhookFailOpen` (warning); `AdmissionWebhookRejections`, `AuthenticationFailures`, `TLSHandshakeErrors`, `APIClientForbidden`, `APIServerMetricsUnavailable` (info) |
| Nodes | `NodeNotReady`, `NodeMemoryPressure`, `NodeDiskPressure`, `NodePIDPressure`, `NodeNetworkUnavailable` (critical); `NodeCPUHigh`, `NodeMemoryHigh`, `NodeDiskHigh`, `NodePIDsHigh`, `NodeStatsUnavailable`, `KubeletRuntimeErrors`, `KubeletEvictions`, `KubeletPLEGSlow`, `VolumeOperationErrors` (warning); `NodeCordoned`, `NodeStatsForbidden`, `NodeNetworkErrors` (info) |
| Containers | `CrashLoopBackOff`, `CrashLooping` (restarting right now), `ImagePullBackOff`/`ErrImagePull`/`InvalidImageName`, `CreateContainerConfigError`/`CreateContainerError`/`RunContainerError`, `OOMKilled` (critical); `HighRestartCount`, `ContainerNotReady`, `LivenessProbeFailures`, `MemoryNearLimit`, `CPUThrottling` (warning) |
| Pods | `Unschedulable`, `PodUnknown` (critical); `PodPendingTooLong`, `PodFailed`, `Evicted`, `PodStuckTerminating` (warning) |
| Workloads | `ProgressDeadlineExceeded` (critical); `DeploymentUnavailable`, `ReplicaFailure`, `StatefulSetNotReady`, `DaemonSetUnavailable`, Job `BackoffLimitExceeded`/`DeadlineExceeded`, HPA `ScalingActive`/`AbleToScale` conditions (warning); `HPAAtMaxReplicas` (info) |
| Storage, quota, network | `PVCPending`, `PVCLost`, `VolumeAlmostFull`, `QuotaExhausted`, `QuotaNearLimit`, `ServiceNoReadyEndpoints` (warning); `NoResourceRequests` (info) |
| Events | every Warning event group: warning for timeout, oom, node, storage and network categories, info otherwise |
| Collector | `CollectorTimeouts`, `CollectorUnreachable`, `CollectorServerErrors`, `APIConnectionRetries` (calls that only succeeded after client-go retried) (warning); `CollectorForbidden`, `CollectorNotFound` (info) |

### Thresholds

Override any of these with `--threshold NAME=VALUE`. They are applied at
analysis time, so `--analyze-only` can re-judge an old run.

| Name | Default | Meaning |
|---|---|---|
| `restart_count` | 3 | restarts before `HighRestartCount` |
| `restart_recent_minutes` | 15 | ...becomes `CrashLooping` (critical) if the last restart is this recent |
| `mem_limit_pct` | 90 | working set as % of memory limit (`MemoryNearLimit`) |
| `cpu_throttle_pct` | 25 | % of CFS periods throttled (`CPUThrottling`) |
| `throttle_min_periods` | 100 | CFS periods (100 ms each) needed before throttling is judged |
| `pending_minutes` | 5 | scheduled pod still Pending (`PodPendingTooLong`) |
| `api_slow_ms` | 1000 | client-side p99 latency (`APIClientSlow`) |
| `etcd_slow_ms` | 250 | etcd p99 per operation (`EtcdSlow`) |
| `apf_wait_ms` | 1000 | APF queue wait p99 (`APFQueueWaitHigh`) |
| `webhook_slow_ms` | 1000 | admission webhook p99 (`AdmissionWebhookSlow`) |
| `pleg_slow_ms` | 1000 | kubelet PLEG relist p99 (`KubeletPLEGSlow`) |
| `node_cpu_pct`, `node_mem_pct` | 90 | node usage as % of allocatable |
| `node_disk_pct` | 85 | node or image filesystem usage |
| `node_pid_pct` | 80 | PIDs in use |
| `volume_pct` | 90 | pod volume bytes or inodes used |
| `quota_pct` | 90 | ResourceQuota usage |

API latency SLO checks use the upstream Kubernetes SLOs: p99 at most 1 s for
mutating and single-object calls, 5 s for namespace-scoped LISTs and 30 s for
cluster-scoped LISTs.

## Output

```
k8s-perf-report/
├── report.md                   verdict, findings, API, nodes, namespaces, containers, events
├── summary.json                everything in the report as structured JSON
├── csv/
│   ├── failures.csv            every finding
│   ├── containers.csv          one row per container
│   ├── namespaces.csv          one row per namespace
│   ├── nodes.csv               one row per node
│   ├── api_client_latency.csv  one row per probed endpoint
│   ├── apiserver_latency.csv   one row per verb/resource/scope
│   ├── apiserver_errors.csv    5xx/429 responses, terminations, aborts, APF rejections
│   ├── events.csv              events aggregated per object/reason, with category
│   └── collector_calls.csv     every API call the run made
├── collector.log               run log, including every timeout and error message
├── meta/                       run.json (options, timings, thresholds), calls.tsv
├── raw/                        API responses; Prometheus scrapes filtered and gzipped
└── analysis/                   intermediate JSON (regenerated by --analyze-only)
```

Exit codes: `0` success, `1` usage or missing prerequisite, `2` API server
unreachable, `3` findings at or above `--fail-on`.

Raw object dumps are redacted by default: env values, `managedFields` and
last-applied annotations are removed. Events and termination messages are kept
verbatim, so treat reports as internal data. Use `--no-redact` to keep everything.

## Least-privilege access

[`manifests/rbac.yaml`](manifests/rbac.yaml) creates the `k8s-perf/k8s-perf-collector`
ServiceAccount with read-only access to everything the collector uses:

```bash
kubectl apply -f manifests/rbac.yaml

# check it - the preflight reports any missing permission
./k8s-perf-collector.sh --dry-run=server --kubectl-arg=--as=system:serviceaccount:k8s-perf:k8s-perf-collector

# run as it with a short-lived token instead of impersonation
TOKEN=$(kubectl -n k8s-perf create token k8s-perf-collector --duration=1h)
kubectl config view --raw --minify > k8s-perf.kubeconfig
kubectl --kubeconfig k8s-perf.kubeconfig config set-credentials k8s-perf-collector --token="$TOKEN"
kubectl --kubeconfig k8s-perf.kubeconfig config set-context --current --user=k8s-perf-collector
./k8s-perf-collector.sh --kubeconfig k8s-perf.kubeconfig
```

> **`nodes/proxy` is powerful.** Kubelet statistics are read through the API
> server's node proxy, which needs `get nodes/proxy`. The Kubernetes RBAC good-practices
> guide warns that this grants the whole kubelet API, including command execution in
> pods. `rbac.yaml` therefore puts it in a separate `k8s-perf-collector-kubelet`
> ClusterRole that you can leave out. Without it, use `--skip-node-stats`: container
> CPU and memory then come from metrics-server, if installed, and throttling, OOM and
> probe counters are not collected.

Missing permissions never abort a run. The affected data is reported as
unavailable (`NodeStatsForbidden`, `APIServerMetricsUnavailable`, ...). With
only namespace `view` rights, `-n <namespace>` still gives full container,
workload and event analysis for that namespace; see
[`samples/dry-run-server-namespace-viewer.txt`](samples/dry-run-server-namespace-viewer.txt).

## In-cluster CronJob

[`manifests/cronjob.yaml`](manifests/cronjob.yaml) runs the collector hourly as
the least-privilege ServiceAccount, as a non-root user with a read-only root
filesystem. It uses the public `alpine/k8s` image, which ships bash, jq and
kubectl; the script is mounted from a ConfigMap. Reports are kept on a PVC for 7 days.

```bash
kubectl apply -f manifests/rbac.yaml
kubectl -n k8s-perf create configmap k8s-perf-collector-script \
  --from-file=k8s-perf-collector.sh --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/cronjob.yaml

# run once now
kubectl -n k8s-perf create job --from=cronjob/k8s-perf-collector k8s-perf-manual
kubectl -n k8s-perf logs -f job/k8s-perf-manual

# copy the latest report off the PVC
kubectl -n k8s-perf run report-reader --image=alpine/k8s:1.37.1 --restart=Never \
  --overrides='{"spec":{"securityContext":{"runAsUser":65534},"containers":[{"name":"report-reader","image":"alpine/k8s:1.37.1","command":["sleep","600"],"volumeMounts":[{"name":"reports","mountPath":"/reports"}]}],"volumes":[{"name":"reports","persistentVolumeClaim":{"claimName":"k8s-perf-reports"}}]}}'
kubectl -n k8s-perf wait --for=condition=Ready pod/report-reader
latest=$(kubectl -n k8s-perf exec report-reader -- readlink /reports/latest)
kubectl -n k8s-perf cp "report-reader:$latest.tar.gz" ./k8s-perf-latest.tar.gz
kubectl -n k8s-perf delete pod report-reader
```

Inside a pod the script writes a kubeconfig for the mounted ServiceAccount
token. kubectl ignores in-cluster credentials whenever a client flag such as
`--request-timeout` is set, and would otherwise try `localhost:8080`.

## CI (Jenkins)

The collector can gate a pipeline: `--fail-on critical` exits 3 when critical
findings exist. For example, as a stage in this repository's `Jenkinsfile`,
with a kubeconfig stored as a Jenkins file credential:

```groovy
stage('Kubernetes health') {
    steps {
        withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG')]) {
            sh 'k8s-perf/k8s-perf-collector.sh --window 60 --fail-on critical --archive -o k8s-perf-report'
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'k8s-perf-report.tar.gz,k8s-perf-report/report.md,k8s-perf-report/csv/*.csv',
                             allowEmptyArchive: true
        }
    }
}
```

## Samples

Everything in [`samples/`](samples/) was produced by this script against a
2-node kind cluster (Kubernetes v1.37.0, kubeadm, containerd) running the demo
manifests. See [`samples/README.md`](samples/README.md) for what each run shows.

| Sample | Scenario |
|---|---|
| [`dry-run-client.txt`](samples/dry-run-client.txt) | `--dry-run`: the full request plan, nothing contacted |
| [`dry-run-server.txt`](samples/dry-run-server.txt) | `--dry-run=server` as the `rbac.yaml` ServiceAccount: every permission granted |
| [`dry-run-server-namespace-viewer.txt`](samples/dry-run-server-namespace-viewer.txt) | preflight as an identity with namespace `view` only: missing permissions listed |
| [`demo-run/`](samples/demo-run/report.md) | broken workloads plus a request flood hitting API Priority & Fairness limits |
| [`degraded-run/`](samples/degraded-run/report.md) | stopped kubelet (NotReady node) plus a flaky network path to the API server |

## Testing

```bash
k8s-perf/tests/test-offline.sh
```

The offline suite needs no cluster. It covers argument validation, the client
dry run (against an unreachable kubeconfig), error classification, kubectl log
parsing, quantity parsing, histogram quantiles and redaction. It also re-runs the
full analysis on both samples, and on synthetic API server metrics with 5xx
responses, 504s, an SLO breach, slow etcd and webhook rejections, then checks the
expected findings.

The live scenarios were reproduced with the demo manifests,
[`demo-apf-throttling.yaml`](manifests/demo-apf-throttling.yaml) and
[`tests/flaky-apiserver-proxy.py`](tests/flaky-apiserver-proxy.py). In the degraded
run, the proxy delayed 30 connections and reset 17. The collector classified them
as 30 timeouts, plus 15 `unreachable` and 2 calls that client-go retried successfully.

## Notes and limits

- **Histogram quantiles** (server-side latency, etcd, APF, kubelet) are interpolated
  within Prometheus buckets, like PromQL's `histogram_quantile`. With few requests in
  the window, p99 lands near the upper edge of a bucket, for example 24.8 ms for
  requests in the 5-25 ms bucket.
- **CPU throttling and probe counters** come from cumulative kubelet counters
  (since container or kubelet start). CPU and memory usage are the kubelet's current values.
- **The collector's own requests** (about 130 per run, mostly lightweight GETs) are
  included in the server-side window. Keep `--window` well above the collection time
  if you want the delta to reflect mostly other traffic.
- **Events** are only retained for about an hour by default, so the event analysis
  covers recent history only.
- **Large clusters:** use `-n` to scope, `--max-nodes` to cap kubelet scrapes and
  `--parallel` to scrape more nodes at once. Object lists are paginated by kubectl
  (500 items per request).
- **Control-plane components** other than kube-apiserver (scheduler,
  controller-manager, etcd itself) usually listen on localhost only and are not
  reachable through the API. Their effects show up in events, API latency and etcd metrics.
