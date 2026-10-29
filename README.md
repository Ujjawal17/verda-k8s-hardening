# Verda k8s hardening

Layer by layer controls:

| Layer | Control |
|---|---|
| Hosts | ufw default-deny, only cp-1:22 public, key-only SSH as `admin`, root login off, fail2ban, CIS sysctls |
| Kubernetes | RKE2 `profile: cis` (PSA restricted default, audit log, kernel defaults), control plane tainted, etcd secrets encryption |
| Network | Cilium: default-deny in every non-platform namespace, L7 (GET-only), FQDN egress and DNS allow-lists (no DNS exfil), cluster-wide deny to metadata and kubelet, WireGuard between nodes, Hubble |
| Admission | Kyverno (fail-closed, 3 replicas): PSS Restricted, no `:latest`, publisher allow-list, digest pinning, cosign signature verification, no SA token, read-only root FS, limits, no NodePort/LoadBalancer, namespace-label guard |
| Multi-tenancy | `demo` (standard tier) and `tenant-b` (untrusted tier, gVisor required): own namespace, quota, default-deny, `tenant-developer` RBAC, own AppProject |
| GitOps | Argo CD app-of-apps, tenant projects cannot touch RBAC, quotas, network policy or other namespaces and no admin login is allowed, signed commits, branch protection and CI gate |
| Scanning | Trivy Operator (images, config, CIS/NSA/PSS compliance), kube-bench |
| Runtime | Falco (modern eBPF) |
| Secrets | Sealed Secrets with an offline-generated key |
| Observability | Prometheus, Grafana "Security plane" dashboard, 5 security alerts |

## Directory structure

infra/        Terraform for provisoning 3 nodes on verda
bootstrap/    bootstrap script to configure RKE2, Cilium, Argo CD once
argocd/       It has AppProjects with one application per component
policies/     custom kyverno validating policies with cluster-wide cilium policy
tenancy/      platform enforced fences per tenant (namespace, quota, limits, network policy, RBAC) and gVisor RuntimeClass
apps/         two tenant apps: demo (nginx -> podinfo), and tenant-b (podinfo in gVisor)
monitoring/   alerts, dashboard, cilium scrape config, sealed grafana secret
tests/        offline tests used in ci workflow: chart rendering py script and kyverno test
scripts/      seal-secrets.sh to create secret offline, and demo.sh for creating demo log md file

## How to run it:

`terraform -chdir=infra output node_ips`
for control plane: `ssh admin@<cp-1>` and workers: `ssh -J admin@<cp-1> admin@<worker>`
`ssh -N -L 6443:127.0.0.1:6443 admin@<cp-1>` then `export KUBECONFIG=$PWD/kubeconfig`
for  Grafana `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` then http://localhost:3000 on browser, user `admin`, password in `.secrets/grafana-admin-password`
for Argo CD `kubectl -n argocd port-forward svc/argocd-server 8080:443` then https://localhost:8080 on browser, user `viewer` (read-only), mentioned below to set password
for Hubble UI `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` then http://localhost:12000 on browser
for Prometheus `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090`

To set the Argo CD viewer password (since the admin login is disabled):
```bash
openssl rand -base64 18 > .secrets/argocd-viewer-password
HASH=$(kubectl -n argocd exec deploy/argocd-server -- argocd account bcrypt --password "$(cat .secrets/argocd-viewer-password)")
kubectl -n argocd patch secret argocd-secret -p \
  "{\"stringData\":{\"accounts.viewer.password\":\"$HASH\",\"accounts.viewer.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
```

## Flow

1. First need to Write the policy in `policies/` with a pass and a fail case in `tests/kyverno/`.
2. It can be tested offline using `python3 tests/render.py && kyverno test tests/kyverno`
3. Then create a PR which will trigger CI (`.github/workflows/ci.yaml`) checking policy tests, kubeconform, tenant image CVE gate. Also, the branch protection on `main` requires signed commits. The CI checks can be added as required status checks.
4. Once Merged, argo will syncs the `policies` app. New or risky rules start with `validationActions: [Audit]`, are reviewed
   in PolicyReports (`kubectl get policyreports -A`), then switched to `[Deny]` in a second PR.
5. to prove live on the cluster, `scripts/demo.sh` can be used which will run the test and add it to the demo log.
