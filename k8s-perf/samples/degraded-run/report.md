# Kubernetes performance and failure report

| | |
|---|---|
| Cluster context | kind-k8s-perf |
| Kubernetes version | v1.37.0 (linux/amd64) |
| Collected | 2026-10-12T18:08:37Z to 2026-10-12T18:10:24Z (107s) |
| Scope | all namespaces |
| API server metrics | unavailable |
| Inventory | 2 nodes, 8 namespaces, 23 pods, 23 containers |
| Collector | k8s-perf-collector 1.0.0, 127 API calls |

## Verdict: CRITICAL

**21 critical**, **39 warning** and 20 informational findings.

| Category | Critical | Warning | Info |
| --- | --- | --- | --- |
| timeout | 9 | 2 | 0 |
| workload | 4 | 11 | 0 |
| crashloop | 3 | 0 | 3 |
| node | 1 | 5 | 0 |
| scheduling | 1 | 0 | 4 |
| config | 1 | 0 | 1 |
| image | 1 | 0 | 1 |
| oom | 1 | 0 | 0 |
| api-error | 0 | 7 | 0 |
| network | 0 | 3 | 0 |
| data | 0 | 2 | 1 |
| collector | 0 | 2 | 0 |
| failed | 0 | 2 | 0 |
| storage | 0 | 2 | 0 |
| job | 0 | 1 | 1 |
| quota | 0 | 1 | 0 |
| readiness | 0 | 1 | 0 |
| probe | 0 | 0 | 5 |
| other | 0 | 0 | 2 |
| resources | 0 | 0 | 2 |

### Critical and warning findings

| Severity | Category | Namespace | Object | Reason | Message |
| --- | --- | --- | --- | --- | --- |
| critical | config | perf-demo-broken | pod/missing-config-78b5446d5b-kckhh container/app | CreateContainerConfigError | configmap "app-settings-that-does-not-exist" not found |
| critical | crashloop | perf-demo-broken | pod/crashloop-7c4d45dccd-vq76x container/app | CrashLoopBackOff | restarts=10; last termination: Error exit=1 db connection refused  |
| critical | crashloop | perf-demo-broken | pod/liveness-fail-c7cf4cd57-jrlbf container/web | CrashLoopBackOff | restarts=15; last termination: Completed exit=0  |
| critical | crashloop | perf-demo-broken | pod/oom-58dddd6dd7-5jh5w container/hog | CrashLoopBackOff | restarts=10; last termination: OOMKilled exit=137  |
| critical | image | perf-demo-broken | pod/bad-image-7c7dbf9f88-vdzk6 container/app | ImagePullBackOff | image registry.invalid/k8s-perf/does-not-exist:0.0.1: Back-off pulling image "registry.invalid/k8s-perf/does-not-exist:0.0.1": ErrImagePull: failed to pull and unpack image "registry.invalid/k8s-perf/does-not-exist:0.0.1": failed to resolve... |
| critical | node | - | node/k8s-perf-worker | NodeNotReady | NodeStatusUnknown Kubelet stopped posting node status. |
| critical | oom | perf-demo-broken | pod/oom-58dddd6dd7-5jh5w container/hog | OOMKilled | memory limit 24Mi, working set n/a (container not running), restarts=10, last OOM kill 2026-10-12T18:04:01Z |
| critical | scheduling | perf-demo-broken | pod/unschedulable-5f4dbb5b47-9px79 | Unschedulable | pending 34.1 min: 0/2 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling. |
| critical | timeout | - | /api/v1/events?limit=500 | APIClientTimeout | 6/10 requests to /api/v1/events?limit=500 timed out (request timeout 3s) |
| critical | timeout | - | /api/v1/namespaces/kube-system | APIClientTimeout | 5/10 requests to /api/v1/namespaces/kube-system timed out (request timeout 3s) |
| critical | timeout | - | /api/v1/namespaces?limit=500 | APIClientTimeout | 1/10 requests to /api/v1/namespaces?limit=500 timed out (request timeout 3s) |
| critical | timeout | - | /api/v1/nodes?limit=500 | APIClientTimeout | 1/10 requests to /api/v1/nodes?limit=500 timed out (request timeout 3s) |
| critical | timeout | - | /api/v1/pods?limit=500 | APIClientTimeout | 6/10 requests to /api/v1/pods?limit=500 timed out (request timeout 3s) |
| critical | timeout | - | /apis | APIClientTimeout | 2/10 requests to /apis timed out (request timeout 3s) |
| critical | timeout | - | /apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases?limit=500 | APIClientTimeout | 1/10 requests to /apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases?limit=500 timed out (request timeout 3s) |
| critical | timeout | - | /readyz | APIClientTimeout | 2/10 requests to /readyz timed out (request timeout 3s) |
| critical | timeout | - | /version | APIClientTimeout | 2/10 requests to /version timed out (request timeout 3s) |
| critical | workload | perf-demo-broken | deployment/bad-image | ProgressDeadlineExceeded | ReplicaSet "bad-image-7c7dbf9f88" has timed out progressing. |
| critical | workload | perf-demo-broken | deployment/missing-config | ProgressDeadlineExceeded | ReplicaSet "missing-config-78b5446d5b" has timed out progressing. |
| critical | workload | perf-demo-broken | deployment/probe-timeout | ProgressDeadlineExceeded | ReplicaSet "probe-timeout-674f6f466d" has timed out progressing. |
| critical | workload | perf-demo-broken | deployment/unschedulable | ProgressDeadlineExceeded | ReplicaSet "unschedulable-5f4dbb5b47" has timed out progressing. |
| warning | api-error | - | /api/v1/namespaces/kube-system | APIClientErrors | 2/10 requests failed: unreachable x2: Unable to connect to the server: read tcp 127.0.0.1:52110->127.0.0.1:16443: read: connection reset by peer |
| warning | api-error | - | /api/v1/namespaces?limit=500 | APIClientErrors | 1/10 requests failed: unreachable x1: Unable to connect to the server: read tcp 127.0.0.1:48966->127.0.0.1:16443: read: connection reset by peer |
| warning | api-error | - | /api/v1/nodes?limit=500 | APIClientErrors | 1/10 requests failed: unreachable x1: Unable to connect to the server: read tcp 127.0.0.1:59580->127.0.0.1:16443: read: connection reset by peer |
| warning | api-error | - | /api/v1/pods?limit=500 | APIClientErrors | 1/10 requests failed: unreachable x1: Unable to connect to the server: write tcp 127.0.0.1:59582->127.0.0.1:16443: write: connection reset by peer |
| warning | api-error | - | /apis | APIClientErrors | 2/10 requests failed: unreachable x2: Unable to connect to the server: read tcp 127.0.0.1:52106->127.0.0.1:16443: read: connection reset by peer |
| warning | api-error | - | /apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases?limit=500 | APIClientErrors | 2/10 requests failed: unreachable x2: Unable to connect to the server: read tcp 127.0.0.1:33260->127.0.0.1:16443: read: connection reset by peer |
| warning | api-error | - | /readyz | APIClientErrors | 3/10 requests failed: unreachable x3: Unable to connect to the server: read tcp 127.0.0.1:52092->127.0.0.1:16443: read: connection reset by peer |
| warning | collector | - | k8s-perf-collector | CollectorServerErrors | 1 call(s): node:k8s-perf-worker:summary - Error from server (ServiceUnavailable): error trying to reach service: dial tcp 172.18.0.2:10250: connect: connection refused |
| warning | collector | - | k8s-perf-collector | CollectorUnreachable | 3 call(s): metrics:apiserver:start, node:k8s-perf-control-plane:kubelet, node:k8s-perf-worker:probes - Unable to connect to the server: write tcp 127.0.0.1:52074->127.0.0.1:16443: write: connection reset by peer |
| warning | data | - | node/k8s-perf-control-plane | NodeStatsUnavailable | kubelet endpoints via node proxy: summary=ok, cadvisor=ok, probes=ok, kubelet=unreachable |
| warning | data | - | node/k8s-perf-worker | NodeStatsUnavailable | kubelet endpoints via node proxy: summary=server_error, cadvisor=timeout, probes=unreachable, kubelet=timeout |
| warning | failed | perf-demo-broken | pod/failing-job-nmhrr | PodFailed | migrate: Error exit=3  |
| warning | failed | perf-demo-broken | pod/failing-job-s88tw | PodFailed | migrate: Error exit=3  |
| warning | job | perf-demo-broken | job/failing-job | BackoffLimitExceeded | Job has reached the specified backoff limit (failed pods: 2) |
| warning | network | - | k8s-perf-collector | APIConnectionRetries | 2 call(s) succeeded only after client-go retried failed connections (flaky network path to the API server): list:nodes, list:services |
| warning | network | perf-demo-broken | service/crashloop | ServiceNoReadyEndpoints | selector app=crashloop matches no ready pod - connections to this service fail |
| warning | network | perf-demo-web | service/web | ServiceNoReadyEndpoints | selector app=web matches no ready pod - connections to this service fail |
| warning | node | kube-system | pod/kindnet-fl7hh | NodeNotReady | x1 (last 2026-10-12T18:08:22Z): Node is not ready |
| warning | node | kube-system | pod/kube-proxy-jqpx5 | NodeNotReady | x1 (last 2026-10-12T18:08:22Z): Node is not ready |
| warning | node | perf-demo-web | pod/cpu-throttled-worker-f5f954dc6-5hmzg | NodeNotReady | x1 (last 2026-10-12T18:08:22Z): Node is not ready |
| warning | node | perf-demo-web | pod/web-7ccbb48844-l2h7j | NodeNotReady | x1 (last 2026-10-12T18:08:22Z): Node is not ready |
| warning | node | perf-demo-web | pod/web-7ccbb48844-m4v9d | NodeNotReady | x1 (last 2026-10-12T18:08:22Z): Node is not ready |
| warning | quota | perf-demo-web | resourcequota/web-quota | QuotaExhausted | pods: used 3 of 3 (100%) - new pods, including rolling-update surge pods, will be rejected |
| warning | readiness | perf-demo-broken | pod/probe-timeout-674f6f466d-qm7rs container/app | ContainerNotReady | running but not ready |
| warning | storage | perf-demo-broken | persistentvolumeclaim/data-pending | ProvisioningFailed | x122 (last 2026-10-12T18:06:21Z): storageclass.storage.k8s.io "no-such-storage-class" not found |
| warning | storage | perf-demo-broken | pvc/data-pending | PVCPending | storageClass=no-such-storage-class; ProvisioningFailed: storageclass.storage.k8s.io "no-such-storage-class" not found |
| warning | timeout | - | k8s-perf-collector | CollectorTimeouts | 4 call(s): node:k8s-perf-worker:cadvisor, node:k8s-perf-worker:kubelet, metrics:metrics-server:pods, metrics:apiserver:end - Unable to connect to the server: context deadline exceeded (Client.Timeout exceeded while awaiting headers) |
| warning | timeout | perf-demo-broken | pod/probe-timeout-674f6f466d-qm7rs | Unhealthy | x373 (last 2026-10-12T18:06:23Z): Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |
| warning | workload | kube-system | daemonset/kindnet | DaemonSetUnavailable | ready 1/2, unavailable 1, misscheduled 0 |
| warning | workload | kube-system | daemonset/kube-proxy | DaemonSetUnavailable | ready 1/2, unavailable 1, misscheduled 0 |
| warning | workload | perf-demo-broken | deployment/bad-image | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/crashloop | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/liveness-fail | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/missing-config | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/oom | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/probe-timeout | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-broken | deployment/unschedulable | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-web | deployment/cpu-throttled-worker | DeploymentUnavailable | 0/1 replicas available (updated=1, unavailable=1) |
| warning | workload | perf-demo-web | deployment/web | DeploymentUnavailable | 0/2 replicas available (updated=2, unavailable=2) |

Informational findings are listed in `csv/failures.csv`.

## Kubernetes API

### Health endpoints

- `/livez`: ok - `/readyz`: ok - all checks passing

### Client-side latency

Measured by this collector: HTTP round trip reported by client-go (`kubectl -v=6`). *Avg wall* adds kubectl process start-up.

| Endpoint | Path | Samples | OK | Timeouts | Errors | p50 ms | p90 ms | p99 ms | Max ms | Avg wall ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| discovery | /apis | 10 | 6 | 2 | 2 | 8 | 12 | 12 | 12 | 85.2 |
| get-namespace | /api/v1/namespaces/kube-system | 10 | 3 | 5 | 2 | 13 | 17 | 17 | 17 | 93 |
| list-events | /api/v1/events?limit=500 | 10 | 4 | 6 | 0 | 17 | 26 | 26 | 26 | 93 |
| list-leases | /apis/coordination.k8s.io/v1/namespaces/kube-node-lease/leases?limit=500 | 10 | 7 | 1 | 2 | 11 | 14 | 14 | 14 | 91.7 |
| list-namespaces | /api/v1/namespaces?limit=500 | 10 | 8 | 1 | 1 | 12 | 13 | 13 | 13 | 88.6 |
| list-nodes | /api/v1/nodes?limit=500 | 10 | 8 | 1 | 1 | 13 | 15 | 15 | 15 | 100 |
| list-pods | /api/v1/pods?limit=500 | 10 | 3 | 6 | 1 | 15 | 19 | 19 | 19 | 103 |
| livez | /livez | 10 | 10 | 0 | 0 | 10 | 12 | 14 | 14 | 91.9 |
| readyz | /readyz | 10 | 5 | 2 | 3 | 13 | 14 | 14 | 14 | 102.8 |
| version | /version | 10 | 8 | 2 | 0 | 8 | 12 | 12 | 12 | 84.5 |

### Server-side (kube-apiserver /metrics)

_kube-apiserver /metrics was not available._

## Nodes

| Node | Roles | Ready | Pods | CPU use/alloc m | CPU req % | CPU lim % | Mem use/alloc Mi | Mem req % | Mem lim % | Disk % | PIDs % | Kubelet |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| k8s-perf-control-plane | control-plane | True | 9 | 286 / 4000 | 23.8 | 0 | 666.3 / 16093.2 | 1.8 | 2.1 | 4.9 | 0.5 | v1.37.0 |
| k8s-perf-worker | none | Unknown | 11 | - / 4000 | 6.8 | 21.3 | - / 16093.2 | 1.2 | 1.6 | - | - | v1.37.0 |

### Kubelet health

| Node | PLEG relist p99 ms | Pod start p99 ms | Slowest runtime op (p99 ms) | Runtime errors | Evictions | Stats endpoints |
| --- | --- | --- | --- | --- | --- | --- |
| k8s-perf-control-plane | - | - | - | 0 | 0 | summary=ok cadvisor=ok probes=ok kubelet=unreachable |
| k8s-perf-worker | - | - | - | 0 | 0 | summary=server_error cadvisor=timeout probes=unreachable kubelet=timeout |

## Namespaces

| Namespace | Pods run/pend/fail/done | Containers | Not ready | Restarts | CPU use/req m | Mem use/req Mi | No requests | Warning events | Quota max % |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| default | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 3 | - |
| k8s-perf | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 0 | - |
| kube-node-lease | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 0 | - |
| kube-public | 0/0/0/0 | 0 | 0 | 0 | - / 0 | - / 0 | 0 | 0 | - |
| kube-system | 10/0/0/0 | 10 | 0 | 0 | 156.9 / 1050 | 453.4 / 340 | 2 | 6 | - |
| local-path-storage | 1/0/0/0 | 1 | 0 | 0 | 0.2 / 0 | 7.8 / 0 | 1 | 1 | - |
| perf-demo-broken | 4/3/2/0 | 9 | 4 | 35 | - / 64060 | - / 72 | 0 | 898 | - |
| perf-demo-web | 3/0/0/0 | 3 | 0 | 0 | - / 110 | - / 72 | 0 | 5 | 100 |

## Containers

23 containers, 15 running, 4 not ready, 35 restarts in total; usage known for 9.

### Unhealthy containers

| Namespace | Pod | Container | State | Reason | Restarts | Last termination | Message |
| --- | --- | --- | --- | --- | --- | --- | --- |
| perf-demo-broken | bad-image-7c7dbf9f88-vdzk6 | app | waiting | ImagePullBackOff | 0 | - | Back-off pulling image "registry.invalid/k8s-perf/does-not-exist:0.0.1": ErrImagePull: failed to pull and unpack image "... |
| perf-demo-broken | crashloop-7c4d45dccd-vq76x | app | waiting | CrashLoopBackOff | 10 | Error exit=1 | back-off 5m0s restarting failed container=app pod=crashloop-7c4d45dccd-vq76x_perf-demo-broken(40e4f1b3-1453-4aad-a6a5-40... |
| perf-demo-broken | failing-job-nmhrr | migrate | terminated | Error | 0 | - | - |
| perf-demo-broken | failing-job-s88tw | migrate | terminated | Error | 0 | - | - |
| perf-demo-broken | liveness-fail-c7cf4cd57-jrlbf | web | waiting | CrashLoopBackOff | 15 | Completed exit=0 | back-off 5m0s restarting failed container=web pod=liveness-fail-c7cf4cd57-jrlbf_perf-demo-broken(0204d649-e856-4ef7-b97b... |
| perf-demo-broken | missing-config-78b5446d5b-kckhh | app | waiting | CreateContainerConfigError | 0 | - | configmap "app-settings-that-does-not-exist" not found |
| perf-demo-broken | oom-58dddd6dd7-5jh5w | hog | waiting | CrashLoopBackOff | 10 | OOMKilled exit=137 | back-off 5m0s restarting failed container=hog pod=oom-58dddd6dd7-5jh5w_perf-demo-broken(3db440e3-682c-4db6-9aaa-c60e3b09... |

### Top CPU

| Namespace | Pod | Container | CPU m | Request m | Limit m | % of limit | Throttled % |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kube-system | kube-apiserver-k8s-perf-control-plane | kube-apiserver | 67.8 | 250 | - | - | - |
| kube-system | etcd-k8s-perf-control-plane | etcd | 39.1 | 100 | - | - | - |
| kube-system | kube-controller-manager-k8s-perf-control-plane | kube-controller-manager | 34 | 200 | - | - | - |
| kube-system | kube-scheduler-k8s-perf-control-plane | kube-scheduler | 11 | 100 | - | - | - |
| kube-system | coredns-559f6c778d-99zpd | coredns | 2.4 | 100 | - | - | - |
| kube-system | coredns-559f6c778d-sszkj | coredns | 2.2 | 100 | - | - | - |
| kube-system | kindnet-wz7vm | kindnet-cni | 0.3 | 100 | - | - | - |
| local-path-storage | local-path-provisioner-75f7fc7dc5-856sx | local-path-provisioner | 0.2 | - | - | - | - |
| kube-system | kube-proxy-d7ns5 | kube-proxy | 0.1 | - | - | - | - |

### Top memory

| Namespace | Pod | Container | Working set Mi | Request Mi | Limit Mi | % of limit | OOM events |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kube-system | kube-apiserver-k8s-perf-control-plane | kube-apiserver | 270 | - | - | - | 0 |
| kube-system | kube-controller-manager-k8s-perf-control-plane | kube-controller-manager | 66.4 | - | - | - | 0 |
| kube-system | etcd-k8s-perf-control-plane | etcd | 44.8 | 100 | - | - | 0 |
| kube-system | kube-scheduler-k8s-perf-control-plane | kube-scheduler | 25 | - | - | - | 0 |
| kube-system | coredns-559f6c778d-99zpd | coredns | 13.2 | 70 | 170 | 7.8 | 0 |
| kube-system | coredns-559f6c778d-sszkj | coredns | 13 | 70 | 170 | 7.6 | 0 |
| kube-system | kube-proxy-d7ns5 | kube-proxy | 12.1 | - | - | - | 0 |
| kube-system | kindnet-wz7vm | kindnet-cni | 8.9 | 50 | - | - | 0 |
| local-path-storage | local-path-provisioner-75f7fc7dc5-856sx | local-path-provisioner | 7.8 | - | - | - | 0 |

### CPU throttling (CFS, since container start)

_none_

### Most restarts

| Namespace | Pod | Container | Restarts | Last reason | Exit code | Finished | Message |
| --- | --- | --- | --- | --- | --- | --- | --- |
| perf-demo-broken | liveness-fail-c7cf4cd57-jrlbf | web | 15 | Completed | 0 | 2026-10-12T18:03:40Z | - |
| perf-demo-broken | crashloop-7c4d45dccd-vq76x | app | 10 | Error | 1 | 2026-10-12T18:02:47Z | db connection refused  |
| perf-demo-broken | oom-58dddd6dd7-5jh5w | hog | 10 | OOMKilled | 137 | 2026-10-12T18:04:01Z | - |

## Events

1431 events (913 warning occurrences).

### Warning events by reason

| Reason | Category | Occurrences | Objects | Example message |
| --- | --- | --- | --- | --- |
| Unhealthy | probe,timeout | 393 | 6 | Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |
| Failed | config,image | 282 | 2 | Error: configmap "app-settings-that-does-not-exist" not found |
| ProvisioningFailed | storage | 122 | 1 | storageclass.storage.k8s.io "no-such-storage-class" not found |
| BackOff | crashloop | 95 | 3 | Back-off restarting failed container web in pod liveness-fail-c7cf4cd57-jrlbf_perf-demo-broken(0204d649-e856-4ef7-b97b-451f33cdde5c) |
| FailedScheduling | scheduling | 12 | 4 | 0/2 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling. |
| NodeNotReady | node | 5 | 5 | Node is not ready |
| CgroupV1 | other | 3 | 2 | cgroup v1 detected. cgroup v1 support is deprecated and will be removed in a future release. Please migrate to cgroup v2. More information at https://git.k8s.io/enhancements/keps/sig-node/5573-remove-... |
| BackoffLimitExceeded | job | 1 | 1 | Job has reached the specified backoff limit |

### Timeouts

| Namespace | Object | Reason | Count | Last seen | Message |
| --- | --- | --- | --- | --- | --- |
| perf-demo-broken | Pod/probe-timeout-674f6f466d-qm7rs | Unhealthy | 373 | 2026-10-12T18:06:23Z | Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |

### Most recent warning events

| Last seen | Namespace | Object | Reason | Count | Message |
| --- | --- | --- | --- | --- | --- |
| 2026-10-12T18:08:22Z | perf-demo-web | Pod/web-7ccbb48844-m4v9d | NodeNotReady | 1 | Node is not ready |
| 2026-10-12T18:08:22Z | perf-demo-web | Pod/web-7ccbb48844-l2h7j | NodeNotReady | 1 | Node is not ready |
| 2026-10-12T18:08:22Z | perf-demo-web | Pod/cpu-throttled-worker-f5f954dc6-5hmzg | NodeNotReady | 1 | Node is not ready |
| 2026-10-12T18:08:22Z | kube-system | Pod/kube-proxy-jqpx5 | NodeNotReady | 1 | Node is not ready |
| 2026-10-12T18:08:22Z | kube-system | Pod/kindnet-fl7hh | NodeNotReady | 1 | Node is not ready |
| 2026-10-12T18:07:19Z | perf-demo-broken | Pod/liveness-fail-c7cf4cd57-jrlbf | BackOff | 38 | Back-off restarting failed container web in pod liveness-fail-c7cf4cd57-jrlbf_perf-demo-broken(0204d649-e856-4ef7-b97b-451f33cdde5c) |
| 2026-10-12T18:07:02Z | perf-demo-broken | Pod/unschedulable-5f4dbb5b47-9px79 | FailedScheduling | 9 | 0/2 nodes are available: 1 Insufficient cpu, 1 node(s) had untolerated taint(s). preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling... |
| 2026-10-12T18:06:57Z | perf-demo-broken | Pod/oom-58dddd6dd7-5jh5w | BackOff | 27 | Back-off restarting failed container hog in pod oom-58dddd6dd7-5jh5w_perf-demo-broken(3db440e3-682c-4db6-9aaa-c60e3b09f02c) |
| 2026-10-12T18:06:39Z | perf-demo-broken | Pod/crashloop-7c4d45dccd-vq76x | BackOff | 30 | Back-off restarting failed container app in pod crashloop-7c4d45dccd-vq76x_perf-demo-broken(40e4f1b3-1453-4aad-a6a5-406d7489c4d6) |
| 2026-10-12T18:06:28Z | perf-demo-broken | Pod/missing-config-78b5446d5b-kckhh | Failed | 142 | Error: configmap "app-settings-that-does-not-exist" not found |
| 2026-10-12T18:06:26Z | perf-demo-broken | Pod/bad-image-7c7dbf9f88-vdzk6 | Failed | 140 | Error: ImagePullBackOff |
| 2026-10-12T18:06:23Z | perf-demo-broken | Pod/probe-timeout-674f6f466d-qm7rs | Unhealthy | 373 | Readiness probe failed: command timed out: "sh -c sleep 5" timed out after 1s |
| 2026-10-12T18:06:21Z | perf-demo-broken | PersistentVolumeClaim/data-pending | ProvisioningFailed | 122 | storageclass.storage.k8s.io "no-such-storage-class" not found |
| 2026-10-12T17:42:31Z | perf-demo-broken | Pod/liveness-fail-c7cf4cd57-jrlbf | Unhealthy | 16 | Liveness probe failed: Get "http://10.244.1.10:8081/healthz": dial tcp 10.244.1.10:8081: connect: connection refused |
| 2026-10-12T17:36:35Z | perf-demo-broken | Job/failing-job | BackoffLimitExceeded | 1 | Job has reached the specified backoff limit |
| 2026-10-12T17:36:20Z | perf-demo-web | Pod/web-7ccbb48844-m4v9d | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.1.3:80/": dial tcp 10.244.1.3:80: connect: connection refused |
| 2026-10-12T17:36:20Z | perf-demo-web | Pod/web-7ccbb48844-l2h7j | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.1.2:80/": dial tcp 10.244.1.2:80: connect: connection refused |
| 2026-10-12T17:34:23Z | kube-system | Pod/coredns-559f6c778d-sszkj | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.0.4:8181/ready": dial tcp 10.244.0.4:8181: connect: connection refused |
| 2026-10-12T17:34:23Z | kube-system | Pod/coredns-559f6c778d-99zpd | Unhealthy | 1 | Readiness probe failed: Get "http://10.244.0.2:8181/ready": dial tcp 10.244.0.2:8181: connect: connection refused |
| 2026-10-12T17:34:11Z | default | Node/k8s-perf-worker | CgroupV1 | 1 | cgroup v1 detected. cgroup v1 support is deprecated and will be removed in a future release. Please migrate to cgroup v2. More information at https://git.k8s.io... |

## Data sources and collector run

| Source | Status |
| --- | --- |
| kube-apiserver /metrics | start=unreachable, end=timeout, mode=unavailable |
| kubelet Summary API | 1/2 nodes ok |
| cAdvisor | 1/2 nodes ok |
| kubelet prober metrics | 1/2 nodes ok |
| kubelet metrics | 0/2 nodes ok |
| metrics-server | timeout |

| Phase | Calls | Failed | Total HTTP ms | Total wall ms |
| --- | --- | --- | --- | --- |
| apiserver | 2 | 2 | 3003 | 3162 |
| cluster | 5 | 0 | 65 | 1531 |
| metrics | 1 | 1 | 3002 | 3089 |
| node | 8 | 5 | 6135 | 6787 |
| objects | 11 | 0 | 157 | 2283 |
| probe | 100 | 38 | 78763 | 86750 |

Calls by outcome: ok=81, server_error=1, timeout=30, unreachable=15. Every call is listed in `csv/collector_calls.csv`; timeouts and errors are also in `collector.log`.

---
_Generated by k8s-perf-collector 1.0.0. Raw responses are in `raw/`, tables in `csv/`._
