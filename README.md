# devops-essentials-sample-app

This is a simple sample application intended to be used alongside the labs for DevOps Essentials.

## Kubernetes performance and failure collector

[`k8s-perf/`](k8s-perf/) contains `k8s-perf-collector.sh`, a script for any vanilla
Kubernetes cluster. It captures container, namespace, node and Kubernetes API
performance measurements, plus the messages, timeouts, errors and failure
conditions behind them, and writes a Markdown report, a JSON summary and CSV
tables. It needs only `bash`, `kubectl` and `jq`.

```bash
k8s-perf/k8s-perf-collector.sh --dry-run          # show every request, contact nothing
k8s-perf/k8s-perf-collector.sh -o k8s-perf-report  # collect and analyze
```

See [`k8s-perf/README.md`](k8s-perf/README.md) for details, and
[`k8s-perf/samples/`](k8s-perf/samples/) for dry-run output and complete sample reports.
