# Kubernetes performance and failure report

| | |
|---|---|
| Cluster context | kind-k8s-perf |
| Kubernetes version | v1.37.0 (linux/amd64) |
| Collected | 2026-10-12T18:27:29Z to 2026-10-12T18:28:30Z (61s) |
| Scope | all namespaces |
| API server metrics | counter deltas over a 55s observation window |
| Inventory | 2 nodes, 8 namespaces, 24 pods, 24 containers |
| Collector | k8s-perf-collector 1.0.0, 167 API calls |

## Verdict: CRITICAL

**11 critical**, **26 warning** and 21 informational findings.

| Category | Critical | Warning | Info |
| --- | --- | --- | --- |
| workload | 4 | 7 | 0 |
| crashloop | 3 | 0 | 3 |
| scheduling | 1 | 0 | 4 |
| config | 1 | 0 | 1 |
| image | 1 | 0 | 1 |
| oom | 1 | 0 | 0 |
| timeout | 0 | 3 | 0 |
| api-error | 0 | 2 | 0 |
| cpu | 0 | 2 | 0 |
| failed | 0 | 2 | 0 |
| storage | 0 | 2 | 0 |
| throttling | 0 | 2 | 0 |
| probe | 0 | 1 | 5 |
| job | 0 | 1 | 1 |
| network | 0 | 1 | 1 |
| quota | 0 | 1 | 0 |
| readiness | 0 | 1 | 0 |
| runtime | 0 | 1 | 0 |
| other | 0 | 0 | 2 |
| resources | 0 | 0 | 2 |
| collector | 0 | 0 | 1 |

### Critical and warning findings

| Severity | Category | Namespace | Object | Reason | Message |
| --- | --- | --- | --- | --- | --- |
| critical | config | perf-demo-broken | pod/missing-config-78b5446d5b-kckhh container/app | CreateContainerConfigError | configmap "app-settings-that-does-not-exist" not found |
| critical | crashloop | perf-demo-broken | pod/crashloop-7c4d45dccd-vq76x container/app | CrashLooping | restarts=18, last restart 6.5 min ago (Error exit=1); currently terminated - flapping between running and back-off |
| critical | crashloop | perf-demo-broken | pod/liveness-fail-c7cf4cd57-jrlbf container/web | CrashLoopBackOff | restarts=25; last termination: Completed exit=0  |
| critical | crashloop | perf-demo-broken | pod/oom-58dddd6dd7-5jh5w container/hog | CrashLooping | restarts=18, last restart 5.6 min ago (OOMKilled exit=137); currently terminated - flapping between running and back-off |
| critical | image | perf-demo-broken | pod/bad-image-7c7dbf9f88-vdzk6 container/app | ImagePullBackOff | image registry.invalid/k8s-perf/does-not-exist:0.0.1: Back-off pulling image "registry.invalid/k8s-perf/does-not-exist:0.0.1": ErrImagePull: failed to pull and unpack image "registry.invalid/k8s-perf/does-not-exist:0.0.1": failed to resolve... |
| critical | oom | perf-demo-broken | pod/oom-58dddd6dd7-5jh5w container/hog | OOMKilled | memory limit 24Mi, working set n/a (container not running), restarts=18, last OOM kill 2026-10-12T18:22:57Z |
| critical | scheduling | perf-demo-broken | pod/unschedulable-5f4dbb5b47-9px79 | Unschedulable | pending 52.2 min: 0/2 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling. |
| critical | workload | perf-demo-broken | deployment/bad-image | ProgressDeadlineExceeded | ReplicaSet "bad-image-7c7dbf9f88" has timed out progressing. |
| critical | workload | perf-demo-broken | deployment/missing-config | ProgressDeadlineExceeded | ReplicaSet "missing-config-78b5446d5b" has timed out progressing. |
| critical | workload | perf-demo-broken | deployment/probe-timeout | ProgressDeadlineExceeded | ReplicaSet "probe-timeout-674f6f466d" has timed out progressing. |
| critical | workload | perf-demo-broken | deployment/unschedulable | ProgressDeadlineExceeded | ReplicaSet "unschedulable-5f4dbb5b47" has timed out progressing. |
| warning | api-error | - | etcd | EtcdRequestErrors | etcd request errors: getCurrentResourceVersion pods x4 |
| warning | api-error | - | kube-apiserver | APIServer5xx | 4 responses with 5xx (0.1% of 5712) over 55s; top: LIST pods 500 x4 |
| warning | cpu | perf-demo-broken | pod/probe-timeout-674f6f466d-qm7rs container/app | CPUThrottling | 26.7% of CFS periods throttled (limit 50m, usage 1.7m, 22.6s throttled) |
| warning | cpu | perf-demo-web | pod/cpu-throttled-worker-f5f954dc6-5hmzg container/burner | CPUThrottling | 99.4% of CFS periods throttled (limit 50m, usage 50m, 1861.8s throttled) |
| warning | failed | perf-demo-broken | pod/failing-job-nmhrr | PodFailed | migrate: Error exit=3  |
| warning | failed | perf-demo-broken | pod/failing-job-s88tw | PodFailed | migrate: Error exit=3  |
| warning | job | perf-demo-broken | job/failing-job | BackoffLimitExceeded | Job has reached the specified backoff limit (failed pods: 2) |
| warning | network | perf-demo-broken | service/crashloop | ServiceNoReadyEndpoints | selector app=crashloop matches no ready pod - connections to this service fail |
| warning | probe | perf-demo-broken | pod/liveness-fail-c7cf4cd57-jrlbf container/web | LivenessProbeFailures | liveness failures=20, startup failures=0 (kubelet counters) |
| warning | quota | perf-demo-web | resourcequota/web-quota | QuotaExhausted | pods: used 3 of 3 (100%) - new pods, including rolling-update surge pods, will be rejected |
| warning | readiness | perf-demo-broken | pod/probe-timeout-674f6f466d-qm7rs container/app | ContainerNotReady | running but not ready; probe failures: readiness=214 |
| warning | runtime | - | node/k8s-perf-worker | KubeletRuntimeErrors | container runtime operation errors: exec_sync x214, pull_image x8 |
| warning | storage | perf-demo-broken | persistentvolumeclaim/data-pending | ProvisioningFailed | x202 (last 2026-10-12T18:26:22Z): storageclass.storage.k8s.io "no-such-storage-class" not found |
| warning | storage | perf-demo-broken | pvc/data-pending | PVCPending | storageClass=no-such-storage-class; ProvisioningFailed: storageclass.storage.k8s.io "no-such-storage-class" not found |
| warning | throttling | - | kube-apiserver | APFRejectedRequests | API Priority and Fairness rejected requests: perf-demo-starved/perf-demo-flooder reason=concurrency-limit x346 |
| warning | throttling | - | kube-apiserver | APIServerThrottled429 | 347 requests rejected with 429 Too Many Requests over 55s; top: LIST pods x347 |
| warning | timeout | - | kube-apiserver | APIRequestsAborted | requests aborted by the timeout handler: LIST pods x1 |
| warning | timeout | - | kube-apiserver | APIRequestsTerminated | requests terminated by the API server (504 = request timeout; 429s are reported separately): LIST pods code=504 x4 |
| warning | timeout | perf-demo-broken | pod/probe-timeout-674f6f466d-qm7rs | Unhealthy | x559 (last 2026-10-12T18:26:11Z): Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |
| warning | workload | perf-demo-broken | deployment/bad-image | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/crashloop | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/liveness-fail | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/missing-config | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/oom | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/probe-timeout | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/unschedulable | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |

Informational findings are listed in `csv/failures.csv`.

## Kubernetes API

### Health endpoints

- `/livez`: ok - `/readyz`: ok - all checks passing

### Client-side latency

Measured by this collector: HTTP round trip reported by client-go (`kubectl -v=6`). *Avg wall* adds kubectl process start-up.

| Endpoint | Path | Samples | OK | Timeouts | Errors | p50 ms | p90 ms | p99 ms | Max ms | Avg wall ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| cm-create | POST configmaps (k8s-perf) | 10 | 10 | 0 | 0 | 12 | 16 | 17 | 17 | 92.8 |
| cm-delete | DELETE configmap (k8s-perf) | 10 | 10 | 0 | 0 | 12 | 13 | 17 | 17 | 98 |
| cm-get | GET configmap (k8s-perf) | 10 | 10 | 0 | 0 | 9 | 11 | 16 | 16 | 90.4 |
| cm-patch | PATCH configmap (k8s-perf) | 10 | 10 | 0 | 0 | 15 | 18 | 21 | 21 | 98.8 |
| discovery | /apis | 10 | 10 | 0 | 0 | 9 | 67 | 70 | 70 | 389.7 |
| get-namespace | /api/v1/namespaces/kube-system | 10 | 10 | 0 | 0 | 10 | 39 | 45 | 45 | 193.3 |
| list-events | /api/v1/events?limit=500 | 10 | 10 | 0 | 0 | 15 | 84 | 96 | 96 | 336.5 |
| list-leases | /apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases?limit=500 | 10 | 10 | 0 | 0 | 11 | 73 | 84 | 84 | 274.7 |
| list-namespaces | /api/v1/namespaces?limit=500 | 10 | 10 | 0 | 0 | 10 | 80 | 108 | 108 | 395.4 |
| list-nodes | /api/v1/nodes?limit=500 | 10 | 10 | 0 | 0 | 12 | 26 | 54 | 54 | 321.4 |
| list-pods | /api/v1/pods?limit=500 | 10 | 10 | 0 | 0 | 13 | 79 | 153 | 153 | 284.2 |
| livez | /livez | 10 | 10 | 0 | 0 | 11 | 64 | 67 | 67 | 404.6 |
| readyz | /readyz | 10 | 10 | 0 | 0 | 11 | 34 | 38 | 38 | 360.5 |
| version | /version | 10 | 10 | 0 | 0 | 10 | 55 | 80 | 80 | 291.7 |

### Server-side (kube-apiserver /metrics)

| Metric | Value |
|---|---|
| Requests | 5712 (103.855/s) over 55s |
| 5xx / 429 / 401+403 / 409 | 4 / 347 / 0 / 0 |
| Requests terminated / aborted | 350 / 1 |
| APF rejected | 346 |
| In-flight (read-only / mutating) | 1 / 1 |
| Long-running requests (watches) | 170 |
| Watch events/s | 5.945 |
| Latency mutating p50 / p90 / p99 | 10.5 / 23.3 / 48.8 ms (n=124) |
| Latency read-only p50 / p90 / p99 | 4.9 / 21.9 / 44.6 ms (n=5203) |
| Process RSS / CPU / goroutines | 410.3 MiB / 0.687 cores / 2626 |
| Uptime | 3274s |

#### Request latency by verb and resource (top 15 by p99)

Upstream SLOs: p99 <= 1s for mutating and single-object reads, <= 5s namespace LIST, <= 30s cluster LIST. Histogram quantiles are interpolated within buckets.

| Verb | Resource | Scope | Requests | p50 ms | p90 ms | p99 ms | SLO ms | Breach |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| LIST | pods | cluster | 11 | 16 | 24.8 | 189 | 30000 | no |
| PATCH | events | resource | 6 | 25 | 70 | 97 | 1000 | no |
| PATCH | pods/status | resource | 5 | 17.5 | 37.5 | 48.8 | 1000 | no |
| LIST | namespaces | cluster | 10 | 4.2 | 25 | 47.5 | 30000 | no |
| GET | /readyz | - | 64 | 3.6 | 21.8 | 46 | 1000 | no |
| LIST | pods | namespace | 4996 | 5.1 | 21.9 | 44.6 | 5000 | no |
| PUT | leases | resource | 71 | 12.1 | 23 | 41.1 | 1000 | no |
| PUT | deployments/status | resource | 4 | 15 | 23 | 24.8 | 1000 | no |
| LIST | events | cluster | 11 | 15 | 23 | 24.8 | 30000 | no |
| GET | pods | resource | 5 | 15 | 23 | 24.8 | 1000 | no |
| PUT | replicasets/status | resource | 4 | 15 | 23 | 24.8 | 1000 | no |
| DELETE | configmaps | resource | 10 | 5 | 21 | 24.6 | 1000 | no |
| LIST | services | cluster | 2 | 5 | 21 | 24.6 | 30000 | no |
| PATCH | configmaps | resource | 10 | 4.2 | 20 | 24.5 | 1000 | no |
| GET | endpoints | resource | 5 | 4.2 | 20 | 24.5 | 1000 | no |

#### Errors, timeouts and throttling

| Verb | Resource | Code | Count |
| --- | --- | --- | --- |
| LIST | pods | 429 | 347 |
| LIST | pods | 500 | 4 |

Terminated requests:

| Verb | Resource | Code | Count |
| --- | --- | --- | --- |
| LIST | pods | 429 | 346 |
| LIST | pods | 504 | 4 |

APF rejections:

| Priority level | Flow schema | Reason | Count |
| --- | --- | --- | --- |
| perf-demo-starved | perf-demo-flooder | concurrency-limit | 346 |

#### etcd (as seen by kube-apiserver)

| Operation | Requests | p50 ms | p90 ms | p99 ms |
| --- | --- | --- | --- | --- |
| update | 110 | 4.2 | 20.7 | 36.3 |
| getCurrentResourceVersion | 5106 | 3 | 13.8 | 24.5 |
| listStream | 22 | 3.7 | 18.7 | 24.4 |
| get | 81 | 2.9 | 11.5 | 23.7 |
| create | 10 | 2.5 | 4.5 | 5 |
| delete | 10 | 2.5 | 4.5 | 5 |
| listWithCount | 2 | 2.5 | 4.5 | 5 |

#### Largest object counts

| Resource | Objects |
| --- | --- |
| events | 199 |
| clusterroles.rbac.authorization.k8s.io | 79 |
| clusterrolebindings.rbac.authorization.k8s.io | 66 |
| serviceaccounts | 55 |
| pods | 24 |
| apiservices.apiregistration.k8s.io | 22 |
| configmaps | 17 |
| rolebindings.rbac.authorization.k8s.io | 15 |
| roles.rbac.authorization.k8s.io | 13 |
| flowschemas.flowcontrol.apiserver.k8s.io | 12 |

## Nodes

| Node | Roles | Ready | Pods | CPU use/alloc m | CPU req % | CPU lim % | Mem use/alloc Mi | Mem req % | Mem lim % | Disk % | PIDs % | Kubelet |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| k8s-perf-control-plane | control-plane | True | 9 | 478 / 4000 | 23.8 | 0 | 806.9 / 16093.2 | 1.8 | 2.1 | 6.4 | 0.5 | v1.37.0 |
| k8s-perf-worker | none | True | 11 | 132 / 4000 | 6.8 | 21.3 | 356 / 16093.2 | 1.2 | 1.6 | 6.4 | 0.5 | v1.37.0 |

### Kubelet health

| Node | PLEG relist p99 ms | Pod start p99 ms | Slowest runtime op (p99 ms) | Runtime errors | Evictions | Stats endpoints |
| --- | --- | --- | --- | --- | --- | --- |
| k8s-perf-control-plane | 9.4 | 19900 | create_container (3028.9) | 0 | 0 | summary=ok cadvisor=ok probes=ok kubelet=ok |
| k8s-perf-worker | 13.5 | 3670 | stop_container (7125.9) | 222 | 0 | summary=ok cadvisor=ok probes=ok kubelet=ok |

## Namespaces

| Namespace | Pods run/pend/fail/done | Containers | Not ready | Restarts | CPU use/req m | Mem use/req Mi | No requests | Warning events | Quota max % |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| default | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 4 | - |
| k8s-perf | 0/0/0/1 | 1 | 0 | 0 | - / 0 | - / 0 | 0 | 0 | - |
| kube-node-lease | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 0 | - |
| kube-public | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 0 | - |
| kube-system | 10/0/0/0 | 10 | 0 | 0 | 770.2 / 1050 | 542.2 / 340 | 2 | 4 | - |
| local-path-storage | 1/0/0/0 | 1 | 0 | 0 | 0.1 / 0 | 8.2 / 0 | 1 | 1 | - |
| perf-demo-broken | 4/3/2/0 | 9 | 4 | 61 | 1.7 / 64060 | 0.8 / 72 | 0 | 1389 | - |
| perf-demo-web | 3/0/0/0 | 3 | 0 | 0 | 50.2 / 110 | 9 / 72 | 0 | 2 | 100 |

## Containers

24 containers, 15 running, 4 not ready, 61 restarts in total; usage known for 15.

### Unhealthy containers

| Namespace | Pod | Container | State | Reason | Restarts | Last termination | Message |
| --- | --- | --- | --- | --- | --- | --- | --- |
| perf-demo-broken | bad-image-7c7dbf9f88-vdzk6 | app | waiting | ImagePullBackOff | 0 | - | Back-off pulling image "registry.invalid/k8s-perf/does-not-exist:0.0.1": ErrImagePull: failed to pull and unpack image "... |
| perf-demo-broken | crashloop-7c4d45dccd-vq76x | app | terminated | Error | 18 | Error exit=1 | db connection refused  |
| perf-demo-broken | failing-job-nmhrr | migrate | terminated | Error | 0 | - | - |
| perf-demo-broken | failing-job-s88tw | migrate | terminated | Error | 0 | - | - |
| perf-demo-broken | liveness-fail-c7cf4cd57-jrlbf | web | waiting | CrashLoopBackOff | 25 | Completed exit=0 | back-off 5m0s restarting failed container=web pod=liveness-fail-c7cf4cd57-jrlbf_perf-demo-broken(0204d649-e856-4ef7-b97b... |
| perf-demo-broken | missing-config-78b5446d5b-kckhh | app | waiting | CreateContainerConfigError | 0 | - | configmap "app-settings-that-does-not-exist" not found |
| perf-demo-broken | oom-58dddd6dd7-5jh5w | hog | terminated | OOMKilled | 18 | OOMKilled exit=137 | - |

### Top CPU

| Namespace | Pod | Container | CPU m | Request m | Limit m | % of limit | Throttled % |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kube-system | kube-apiserver-k8s-perf-control-plane | kube-apiserver | 532.1 | 250 | - | - | - |
| kube-system | etcd-k8s-perf-control-plane | etcd | 195.6 | 100 | - | - | - |
| perf-demo-web | cpu-throttled-worker-f5f954dc6-5hmzg | burner | 50 | 10 | 50 | 100 | 99.4 |
| kube-system | kube-controller-manager-k8s-perf-control-plane | kube-controller-manager | 25.2 | 200 | - | - | - |
| kube-system | kube-scheduler-k8s-perf-control-plane | kube-scheduler | 9.1 | 100 | - | - | - |
| kube-system | kindnet-wz7vm | kindnet-cni | 2 | 100 | - | - | - |
| kube-system | coredns-559f6c778d-99zpd | coredns | 1.9 | 100 | - | - | - |
| kube-system | coredns-559f6c778d-sszkj | coredns | 1.8 | 100 | - | - | - |
| perf-demo-broken | probe-timeout-674f6f466d-qm7rs | app | 1.7 | 10 | 50 | 3.4 | 26.7 |
| kube-system | kindnet-fl7hh | kindnet-cni | 1.5 | 100 | - | - | - |

### Top memory

| Namespace | Pod | Container | Working set Mi | Request Mi | Limit Mi | % of limit | OOM events |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kube-system | kube-apiserver-k8s-perf-control-plane | kube-apiserver | 333.2 | - | - | - | 0 |
| kube-system | kube-controller-manager-k8s-perf-control-plane | kube-controller-manager | 68.2 | - | - | - | 0 |
| kube-system | etcd-k8s-perf-control-plane | etcd | 48.1 | 100 | - | - | 0 |
| kube-system | kube-scheduler-k8s-perf-control-plane | kube-scheduler | 24.4 | - | - | - | 0 |
| kube-system | coredns-559f6c778d-99zpd | coredns | 13.1 | 70 | 170 | 7.7 | 0 |
| kube-system | coredns-559f6c778d-sszkj | coredns | 13.1 | 70 | 170 | 7.7 | 0 |
| kube-system | kube-proxy-d7ns5 | kube-proxy | 12.1 | - | - | - | 0 |
| kube-system | kube-proxy-jqpx5 | kube-proxy | 12 | - | - | - | 0 |
| kube-system | kindnet-fl7hh | kindnet-cni | 9.2 | 50 | - | - | 0 |
| kube-system | kindnet-wz7vm | kindnet-cni | 8.8 | 50 | - | - | 0 |

### CPU throttling (CFS, since container start)

| Namespace | Pod | Container | Throttled % | Throttled s | Limit m | Usage m |
| --- | --- | --- | --- | --- | --- | --- |
| perf-demo-web | cpu-throttled-worker-f5f954dc6-5hmzg | burner | 99.4 | 1861.8 | 50 | 50 |
| perf-demo-broken | probe-timeout-674f6f466d-qm7rs | app | 26.7 | 22.6 | 50 | 1.7 |
| perf-demo-web | web-7ccbb48844-l2h7j | nginx | 0.5 | 0.2 | 200 | 0.1 |
| perf-demo-web | web-7ccbb48844-m4v9d | nginx | 0.4 | 0 | 200 | 0.1 |

### Most restarts

| Namespace | Pod | Container | Restarts | Last reason | Exit code | Finished | Message |
| --- | --- | --- | --- | --- | --- | --- | --- |
| perf-demo-broken | liveness-fail-c7cf4cd57-jrlbf | web | 25 | Completed | 0 | 2026-10-12T18:27:54Z | - |
| perf-demo-broken | crashloop-7c4d45dccd-vq76x | app | 18 | Error | 1 | 2026-10-12T18:21:59Z | db connection refused  |
| perf-demo-broken | oom-58dddd6dd7-5jh5w | hog | 18 | OOMKilled | 137 | 2026-10-12T18:22:57Z | - |

## Events

2157 events (1400 warning occurrences).

### Warning events by reason

| Reason | Category | Occurrences | Objects | Example message |
| --- | --- | --- | --- | --- |
| Unhealthy | probe,timeout | 592 | 6 | Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |
| Failed | config,image | 426 | 2 | Error: ImagePullBackOff |
| ProvisioningFailed | storage | 202 | 1 | storageclass.storage.k8s.io "no-such-storage-class" not found |
| BackOff | crashloop | 151 | 3 | Back-off restarting failed container hog in pod oom-58dddd6dd7-5jh5w_perf-demo-broken(3db440e3-682c-4db6-9aaa-c60e3b09f02c) |
| FailedScheduling | scheduling | 24 | 4 | 0/2 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling. |
| CgroupV1 | other | 4 | 2 | cgroup v1 detected. cgroup v1 support is deprecated and will be removed in a future release. Please migrate to cgroup v2. More information at https://git.k8s.io/enhancements/keps/sig-node/5573-remove-... |
| BackoffLimitExceeded | job | 1 | 1 | Job has reached the specified backoff limit |

### Timeouts

| Namespace | Object | Reason | Count | Last seen | Message |
| --- | --- | --- | --- | --- | --- |
| perf-demo-broken | Pod/probe-timeout-674f6f466d-qm7rs | Unhealthy | 559 | 2026-10-12T18:26:11Z | Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |

### Most recent warning events

| Last seen | Namespace | Object | Reason | Count | Message |
| --- | --- | --- | --- | --- | --- |
| 2026-10-12T18:28:10Z | perf-demo-broken | Pod/oom-58dddd6dd7-5jh5w | BackOff | 46 | Back-off restarting failed container hog in pod oom-58dddd6dd7-5jh5w_perf-demo-broken(3db440e3-682c-4db6-9aaa-c60e3b09f02c) |
| 2026-10-12T18:27:16Z | perf-demo-broken | Pod/crashloop-7c4d45dccd-vq76x | BackOff | 47 | Back-off restarting failed container app in pod crashloop-7c4d45dccd-vq76x_perf-demo-broken(40e4f1b3-1453-4aad-a6a5-406d7489c4d6) |
| 2026-10-12T18:26:22Z | perf-demo-broken | PersistentVolumeClaim/data-pending | ProvisioningFailed | 202 | storageclass.storage.k8s.io "no-such-storage-class" not found |
| 2026-10-12T18:26:15Z | perf-demo-broken | Pod/bad-image-7c7dbf9f88-vdzk6 | Failed | 213 | Error: ImagePullBackOff |
| 2026-10-12T18:26:13Z | perf-demo-broken | Pod/missing-config-78b5446d5b-kckhh | Failed | 213 | Error: configmap "app-settings-that-does-not-exist" not found |
| 2026-10-12T18:26:11Z | perf-demo-broken | Pod/probe-timeout-674f6f466d-qm7rs | Unhealthy | 559 | Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |
| 2026-10-12T18:26:07Z | perf-demo-broken | Pod/liveness-fail-c7cf4cd57-jrlbf | BackOff | 58 | Back-off restarting failed container web in pod liveness-fail-c7cf4cd57-jrlbf_perf-demo-broken(0204d649-e856-4ef7-b97b-451f33cdde5c) |
| 2026-10-12T18:23:44Z | perf-demo-broken | Pod/unschedulable-5f4dbb5b47-9px79 | FailedScheduling | 21 | 0/2 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling... |
| 2026-10-12T18:22:30Z | perf-demo-broken | Pod/liveness-fail-c7cf4cd57-jrlbf | Unhealthy | 29 | Liveness probe failed: Get "http://10.244.1.10:8081/healthz": dial tcp 10.244.1.10:8081: connect: connection refused |
| 2026-10-12T18:11:03Z | default | Node/k8s-perf-worker | CgroupV1 | 2 | cgroup v1 detected. cgroup v1 support is deprecated and will be removed in a future release. Please migrate to cgroup v2. More information at https://git.k8s.io... |
| 2026-10-12T17:36:35Z | perf-demo-broken | Job/failing-job | BackoffLimitExceeded | 1 | Job has reached the specified backoff limit |
| 2026-10-12T17:36:20Z | perf-demo-web | Pod/web-7ccbb48844-m4v9d | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.1.3:80/": dial tcp 10.244.1.3:80: connect: connection refused |
| 2026-10-12T17:36:20Z | perf-demo-web | Pod/web-7ccbb48844-l2h7j | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.1.2:80/": dial tcp 10.244.1.2:80: connect: connection refused |
| 2026-10-12T17:34:23Z | kube-system | Pod/coredns-559f6c778d-sszkj | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.0.4:8181/ready": dial tcp 10.244.0.4:8181: connect: connection refused |
| 2026-10-12T17:34:23Z | kube-system | Pod/coredns-559f6c778d-99zpd | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.0.2:8181/ready": dial tcp 10.244.0.2:8181: connect: connection refused |
| 2026-10-12T17:34:08Z | local-path-storage | Pod/local-path-provisioner-75f7fc7dc5-856sx | FailedScheduling | 1 | 0/1 nodes are available: 1 node(s) had untolerated taint(s). preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling. |
| 2026-10-12T17:34:08Z | kube-system | Pod/coredns-559f6c778d-sszkj | FailedScheduling | 1 | 0/1 nodes are available: 1 node(s) had untolerated taint(s). preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling. |
| 2026-10-12T17:34:08Z | kube-system | Pod/coredns-559f6c778d-99zpd | FailedScheduling | 1 | 0/1 nodes are available: 1 node(s) had untolerated taint(s). preemption: 0/1 nodes are available: 1 Preemption is not helpful for scheduling. |
| 2026-10-12T17:34:02Z | default | Node/k8s-perf-control-plane | CgroupV1 | 2 | cgroup v1 detected. cgroup v1 support is deprecated and will be removed in a future release. Please migrate to cgroup v2. More information at https://git.k8s.io... |

## Data sources and collector run

| Source | Status |
| --- | --- |
| kube-apiserver /metrics | start=ok, end=ok, mode=window |
| kubelet Summary API | 2/2 nodes ok |
| cAdvisor | 2/2 nodes ok |
| kubelet prober metrics | 2/2 nodes ok |
| kubelet metrics | 2/2 nodes ok |
| metrics-server | not_found |

| Phase | Calls | Failed | Total HTTP ms | Total wall ms |
| --- | --- | --- | --- | --- |
| apiserver | 2 | 0 | 187 | 1243 |
| cluster | 5 | 0 | 194 | 3497 |
| metrics | 1 | 1 | 10 | 88 |
| node | 8 | 0 | 387 | 1026 |
| objects | 11 | 0 | 118 | 1107 |
| probe | 140 | 0 | 3232 | 36320 |

Calls by outcome: not_found=1, ok=166. Every call is listed in `csv/collector_calls.csv`; timeouts and errors are also in `collector.log`.

---
_Generated by k8s-perf-collector 1.0.0. Raw responses are in `raw/`, tables in `csv/`._
