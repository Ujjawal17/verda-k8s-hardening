# Summary

3-node RKE2 cluster on Verda (FIN-01, CPU.4V.16G, Ubuntu 24.04), built with Terraform + one bootstrap script,
then fully owned by Argo CD from this repo. Every control below was triggered on the live cluster on 2026-10-28:
see [demo log](docs/demo-log.md). Threats and residual risk per layer: [threat model](docs/threat-model.md).

## What worked (proven live)

| Control | Attempt | Result |
|---|---|---|
| Host firewall + SSH | Connect to every listening port on all nodes from the internet; root and password SSH | Only cp-1:22 answers; API, etcd, kubelet, RKE2 join blocked; root/password refused |
| Admission (Kyverno + PSA) | `:latest`, untrusted registry, privileged, SA token mounted, NodePort | Each rejected by its own rule; privileged stopped by PSA first (2 layers) |
| GitOps boundary | Tenant Argo project deploys platform fences | Argo refuses all 8 objects (quota, limits, ns, network policies) |
| Network (Cilium) | POST to backend, egress to example.com, metadata IP, kubelet 10250 | GET ok / POST 403 (L7); only backend→api.github.com; rest dropped, visible in Hubble; WireGuard on |
| Runtime (Falco) | Shell in container; API call from a pod | Both detected |
| Alerts | All of the above | `ShellSpawnedInContainer`, `ContainerContactedK8sApi`, `AdmissionRequestsDenied`, `NetworkPolicyDropsSpike`, `CriticalVulnerabilityRunning` all fired |
| Secrets | Read Git, read Secret as tenant SA, etcd status | Ciphertext only; `can-i get secrets` = no; etcd encryption Enabled |
| CIS (kube-bench rke2-cis-1.9) | cp-1, worker-1 | worker 17 PASS / 0 FAIL; cp-1 62 PASS / 4 FAIL (below) |

## What didn't work first time (and what it taught)

- **Bootstrap locked me out of cp-1.** `ssh host bash -s -- args` re-splits args; the SSH key (has spaces) arrived broken
  *after* root login was disabled. No console on Verda → node rebuilt. Fix: `%q` quoting + a guard that refuses to touch sshd
  unless the admin key validates.
- **A chart tried to write into `kube-system`** (CoreDNS scrape Service): the `platform` AppProject blocked it. Kept the project
  tight and dropped the scrape (Hubble has DNS metrics).
- **nmap reported ~660 "open" ports** that nothing listens on (something upstream answers scans). Replaced with a test that
  probes each node's real sockets from outside.
- **Alerts silent on first event:** Falco creates a counter at value 1, which `increase()` cannot see. Rules now also fire on new series.
- **Falco API rule was noise:** Argo CD/Kyverno/Prometheus talk to the API all day. Excepted platform namespaces.
- **Falco only sees API calls that connect:** from the tenant namespace Cilium drops them first (prevention wins, Hubble shows it);
  from `default` (no default-deny) Falco catches it. Detection is the backup layer, not the only one.

## Findings to act on

- **Critical CVEs running:** podinfo 6.8.0 (6 critical; Go stdlib, OpenSSL, grpc — all fixable), argocd v3.5.6 (Go stdlib, fixable),
  k8s-sidecar 2.14.1 (certifi, fixable). Triage: bump image digests via Git; podinfo is the tenant-facing one, first.
- **kube-bench cp-1 FAIL 5.1.1/5.1.3/5.1.5/5.1.6** (cluster-admin use, wildcard roles, default SA, token mounts): from platform
  components (Argo CD, Kyverno, RKE2 add-ons) that need broad rights. Tenant side is clean. Needs a per-component RBAC review.

## Key choices (why X, not Y)

- **RKE2 over kubeadm:** CIS profile, etcd encryption, audit log, PSA by default; fewer hand-made flags to get wrong.
- **Cilium over Calico:** L7 + FQDN policy, WireGuard, Hubble flow evidence in one component.
- **Kyverno (CEL ValidatingPolicy) over Gatekeeper:** policies readable as YAML, built-in PSS set, offline `kyverno test`.
- **Sealed Secrets over ESO:** no external secret store on Verda; ESO would need one. Key generated offline, backed up off-cluster.
- **ufw over Cilium host firewall:** Verda has no cloud firewall, so the host firewall must work before and without the cluster,
  and must not be editable by cluster-admin/Git. Cilium host policy is the next layer, not the replacement.

## Gaps (honest) and next steps

1. Sandbox for untrusted code (gVisor RuntimeClass): tenants share the kernel today. Biggest gap.
2. Default-deny for every namespace, not just tenants (`default` proved it above).
3. Image signatures (cosign + Kyverno `verifyImages`); allow-listed publisher ≠ trusted image.
4. Custom API audit policy, shipped off-cluster with Falco events; today logs stay on cp-1.
5. SSH 22 still public on cp-1 (no console/SSM on Verda): Tailscale/Teleport for zero public ports.
6. Single control plane; long-lived admin cert instead of OIDC per person.
