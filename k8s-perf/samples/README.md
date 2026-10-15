# Sample outputs

All files here were produced by `k8s-perf-collector.sh` against a 2-node
[kind](https://kind.sigs.k8s.io/) cluster: Kubernetes v1.37.0, kubeadm,
containerd 2.3, no metrics-server. The cluster ran
[`demo-failure-scenarios.yaml`](../manifests/demo-failure-scenarios.yaml).
Each full run has the complete output layout; only the regenerable `analysis/`
directory is left out of git. Re-create it, or re-judge a run with different
thresholds, using:

```bash
../k8s-perf-collector.sh --analyze-only demo-run
```

## Dry runs

| File | Command | Shows |
|---|---|---|
| [`dry-run-client.txt`](dry-run-client.txt) | `--dry-run` | prerequisites, configuration and all ~120 planned kubectl calls with their output files; contacts nothing and writes nothing |
| [`dry-run-server.txt`](dry-run-server.txt) | `--dry-run=server --write-probe` as the [`rbac.yaml`](../manifests/rbac.yaml) ServiceAccount | connectivity, cluster size and a SelfSubjectAccessReview per permission; all granted |
| [`dry-run-server-namespace-viewer.txt`](dry-run-server-namespace-viewer.txt) | `--dry-run=server -n perf-demo-web` as a ServiceAccount with namespace `view` only | the 6 cluster-level permissions it lacks; the run would still work for its namespace |

## demo-run: broken workloads and API throttling

[`report.md`](demo-run/report.md) · [`summary.json`](demo-run/summary.json) · [`csv/failures.csv`](demo-run/csv/failures.csv)

Collected as the least-privilege ServiceAccount with `--write-probe`. During
the run, 24 parallel clients flooded the API as a ServiceAccount that
[`demo-apf-throttling.yaml`](../manifests/demo-apf-throttling.yaml) confines to a
tiny API Priority & Fairness level.

Verdict **CRITICAL**: 11 critical, 26 warning, 21 info findings, from 167 API calls in 61 s.

- **Every planted workload failure is found:**
  - `CrashLoopBackOff` / `CrashLooping`: the crashloop and liveness-fail pods, with exit code and termination message
  - `OOMKilled`: exit 137 under a 24 Mi limit
  - `ImagePullBackOff`
  - `CreateContainerConfigError`: the missing ConfigMap is named
  - `Unschedulable`: "0/2 nodes are available: 1 Insufficient cpu ..."
  - `ProgressDeadlineExceeded` on four Deployments
  - Job `BackoffLimitExceeded`, with both failed pods
  - `PVCPending`, with the provisioning error
  - `QuotaExhausted`: pods 3/3, so rolling updates will be blocked
  - `CPUThrottling`: 99.9% of periods for the worker capped at 50m
  - `ContainerNotReady` plus readiness probe timeouts ("command timed out after 1s", 275 failures)
  - `LivenessProbeFailures`
  - `ServiceNoReadyEndpoints`
  - `KubeletRuntimeErrors`: exec_sync and pull_image errors
- **API throttling seen from the server side:** `APIServerThrottled429` and
  `APFRejectedRequests`, 347 requests rejected in the `perf-demo-starved` priority level.
- **Abrupt client disconnects:** when the flood was killed, its in-flight requests
  surfaced as `APIServer5xx` (4), `APIRequestsTerminated` (504), `APIRequestsAborted`,
  `EtcdRequestErrors` (getCurrentResourceVersion on pods) and `TLSHandshakeErrors`.
  These are real kube-apiserver counters, not test fixtures.
- **Client-side latency under load:** p50 9-15 ms, p99 up to 153 ms for `LIST pods`.
  ConfigMap create/get/patch/delete took 12/9/15/12 ms at p50.
- The healthy `web` Deployment in the same cluster produces no findings.

## degraded-run: NotReady node and flaky API path

[`report.md`](degraded-run/report.md) · [`summary.json`](degraded-run/summary.json) · [`collector.log`](degraded-run/collector.log)

The worker's kubelet was stopped until the node went NotReady. The collector
then ran with `--timeout 3` through
[`flaky-apiserver-proxy.py`](../tests/flaky-apiserver-proxy.py), which held 25% of
connections for 8 s and reset 10%.

Verdict **CRITICAL**: 21 critical, 39 warning, 20 info findings. Of 127 calls,
81 were ok, 30 timed out, 15 were unreachable and 1 got a server error.

- `NodeNotReady` ("Kubelet stopped posting node status"), with the knock-on effects:
  `DaemonSetUnavailable` for kube-proxy and kindnet, `DeploymentUnavailable` and
  `ServiceNoReadyEndpoints` for the web tier, and NodeNotReady events on every pod
  of that node.
- `NodeStatsUnavailable`: the node proxy answered 503 "error trying to reach
  service: dial tcp ...:10250: connect: connection refused".
- `APIClientTimeout` on 9 endpoints ("context deadline exceeded (Client.Timeout
  exceeded while awaiting headers)") and `APIClientErrors` for connection resets.
- `CollectorTimeouts` / `CollectorUnreachable` for collection calls that failed,
  and `APIConnectionRetries` for 2 calls that client-go retried successfully.
- Both `/metrics` scrapes failed, so `APIServerMetricsUnavailable` says why
  (scrape 1: unreachable, scrape 2: timeout). The rest of the report is still complete.
- Cross-check: the proxy logged 30 delayed and 17 reset connections. That matches
  the 30 timeouts, and the 15 unreachable calls plus 2 retried ones.
