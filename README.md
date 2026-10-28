# verda-k8s-hardening

Hardened 3-node RKE2 cluster on Verda Cloud. Everything after bootstrap is deployed by Argo CD from this repo.

| Area | Control |
|---|---|
| Hosts | ufw default-deny, only cp-1:22 public, key-only SSH as `admin`, root login off, fail2ban, CIS sysctls |
| Kubernetes | RKE2 `profile: cis` (PSA restricted default, audit log, kernel defaults), control plane tainted, etcd secrets encryption |
| Network | Cilium: default-deny in tenant namespaces, L7 (GET-only) and FQDN egress policies, cluster-wide deny to metadata + kubelet, WireGuard between nodes, Hubble |
| Admission | Kyverno (fail-closed, 3 replicas): PSS Restricted, no `:latest`, publisher allow-list, digest pinning, no SA token, read-only root FS, limits, no NodePort/LoadBalancer |
| GitOps | Argo CD app-of-apps; `workloads` project cannot touch RBAC, quotas, or network policy; no admin login |
| Scanning | Trivy Operator (images, config, CIS/NSA/PSS compliance), kube-bench |
| Runtime | Falco (modern eBPF) |
| Secrets | Sealed Secrets with an offline-generated key |
| Observability | Prometheus, Grafana "Security plane" dashboard, 5 security alerts |

Docs: [threat model](docs/threat-model.md) · [demo log](docs/demo-log.md) · [summary](SUMMARY.md)

## Layout

```
infra/        Terraform: 3 Verda VMs + SSH key (no secrets in state)
bootstrap/    bootstrap.sh + RKE2/Cilium/Argo CD config (run once)
argocd/       AppProjects + one Application per component (app-of-apps)
policies/     custom Kyverno ValidatingPolicies + cluster-wide Cilium policy
tenancy/      platform-owned fences per tenant namespace (quota, limits, network policy)
apps/demo/    tenant app: frontend (nginx) -> backend (podinfo)
monitoring/   alerts, dashboard, Cilium scrape config, sealed Grafana secret
tests/        offline tests: chart rendering + kyverno test suite
scripts/      seal-secrets.sh (offline), demo.sh (proof collection)
```

## Build

Needs: terraform, kubectl, helm, jq, kubeseal, Verda API creds, SSH key `~/.ssh/verda_k8s`.

```bash
source ~/.config/verda/env                 # VERDA_CLIENT_ID / VERDA_CLIENT_SECRET
./scripts/seal-secrets.sh                  # once: sealing keypair + sealed Grafana secret
python3 tests/render.py && kyverno test tests/kyverno   # offline policy tests
terraform -chdir=infra apply
./bootstrap/bootstrap.sh
```

Tear down: `terraform -chdir=infra destroy`.

## Access

Nothing but SSH on cp-1 is public. API server and dashboards go through an SSH tunnel.

| What | How |
|---|---|
| Node IPs | `terraform -chdir=infra output node_ips` |
| SSH | `ssh admin@<cp-1>`; workers: `ssh -J admin@<cp-1> admin@<worker>` |
| kubectl | `ssh -N -L 6443:127.0.0.1:6443 admin@<cp-1>` then `export KUBECONFIG=$PWD/kubeconfig` |
| Grafana | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` → http://localhost:3000, user `admin`, password in `.secrets/grafana-admin-password` |
| Argo CD | `kubectl -n argocd port-forward svc/argocd-server 8080:443` → https://localhost:8080, user `viewer` (read-only), password set below |
| Hubble UI | `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` → http://localhost:12000 |
| Prometheus | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090` |

Set the Argo CD `viewer` password (admin login is disabled):

```bash
openssl rand -base64 18 > .secrets/argocd-viewer-password
HASH=$(kubectl -n argocd exec deploy/argocd-server -- argocd account bcrypt --password "$(cat .secrets/argocd-viewer-password)")
kubectl -n argocd patch secret argocd-secret -p \
  "{\"stringData\":{\"accounts.viewer.password\":\"$HASH\",\"accounts.viewer.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
```

## Prove it

```bash
./scripts/demo.sh      # writes docs/demo-log.md: one blocked attempt per control
```
