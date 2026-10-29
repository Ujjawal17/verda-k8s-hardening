#directory structure
infra/        Terraform for provisoning 3 nodes on verda
bootstrap/    bootstrap script to configure RKE2, Cilium, Argo CD once
argocd/       It has AppProjects with one application per component
policies/     custom kyverno validating policies with cluster-wide cilium policy
tenancy/      platform enforced fences per tenant (namespace, quota, limits, network policy, RBAC) and gVisor RuntimeClass
apps/         two tenant apps: demo (nginx -> podinfo), and tenant-b (podinfo in gVisor)
monitoring/   alerts, dashboard, cilium scrape config, sealed grafana secret
tests/        offline tests used in ci workflow: chart rendering py script and kyverno test
scripts/      seal-secrets.sh to create secret offline, and demo.sh for creating demo log md file

#How to run it:
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
