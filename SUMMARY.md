# Summary

3-node RKE2 cluster on Verda (FIN-01, CPU.4V.16G, Ubuntu 24.04), built with Terraform + one bootstrap script,
then fully owned by Argo CD from this repo. Every control below was triggered on the live cluster on 2026-10-28:
see [demo log](docs/demo-log.md). Threats and residual risk per layer: [threat model](docs/threat-model.md).

## What worked (proven live)

| Control | Attempt | Result |
|---|---|---|
| Host firewall + SSH | Connect to every listening port on all nodes from the internet; root and password SSH | Only cp-1:22 answers; API, etcd, kubelet, RKE2 join blocked; root/password refused |
| Admission (Kyverno + PSA) | `:latest`, untrusted registry, privileged, SA token mounted, NodePort, **unsigned image** | All rejected; privileged stopped by PSA first (2 layers); unsigned podinfo from an allow-listed publisher rejected by cosign verification |
| GitOps boundary | Tenant Argo project deploys platform fences | Argo refuses all 8 objects (quota, limits, ns, network policies) |
| Network (Cilium) | POST to backend, egress to example.com, metadata IP, kubelet 10250, **DNS exfil lookup, pod in `default`** | GET ok / POST 403 (L7); only backend→api.github.com; exfil lookup `REFUSED`; `default` has no network; rest dropped, visible in Hubble; WireGuard on |
| Runtime (Falco) | Shell in container; API call from a pod | Both detected (API call: before cluster-wide default-deny; now it never connects) |
| Alerts | All of the above | `ShellSpawnedInContainer`, `ContainerContactedK8sApi`, `AdmissionRequestsDenied`, `NetworkPolicyDropsSpike`, `CriticalVulnerabilityRunning` all fired |
| Secrets | Read Git, read Secret as tenant SA, etcd status | Ciphertext only; `can-i get secrets` = no; etcd encryption Enabled |
| CIS (kube-bench rke2-cis-1.9) | cp-1, worker-1 | worker 17 PASS / 0 FAIL; cp-1 62 PASS / 4 FAIL (below) |
| Multi-tenancy | tenant-b ↔ demo traffic; tenant-b dev: read demo secrets, deploy into demo, delete own netpol, exec, patch namespace; drop gVisor; remove sandbox label; relax PSA; Argo app into demo | All blocked; tenant-b runs on `4.19.0-gvisor`, demo on the host kernel |
| Supply chain + CI | Unsigned image; fixable CRITICAL CVE; broken policy/manifest | Kyverno verifies podinfo's keyless signature (release workflow identity); CI gate (policy tests, kubeconform, Trivy) green on `main` |

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

- **gVisor needed more than `runsc`:** the current release also needs its `gvisor-bin/` helpers, and the base image lacks `bzip2`.
- **Inside gVisor, host Falco is blind** (shell + API call in a sandboxed pod: no events; only the sentry's own ptrace, now excepted).
  So: two tiers. Untrusted = gVisor (isolation), standard = runc + Falco (visibility).
- **A Cilium cluster-wide policy with no rules enforces nothing**: default-deny needed a "match-nothing" rule. Tested live first.
- **`*` in Cilium DNS patterns does not cross dots**: `**.cluster.local` does. Tested live first.

## Findings to act on

- **Critical CVEs running:** podinfo 6.8.0 (6 critical, all fixable) → **fixed**: bumped to signed 6.15.0 (0 fixable critical).
  Still open: argocd v3.5.6 (Go stdlib, P2, platform) and k8s-sidecar 2.14.1 (certifi, P3). See [CVE triage](docs/cve-triage.md).
- **kube-bench cp-1 FAIL 5.1.1/5.1.3/5.1.5/5.1.6** (cluster-admin use, wildcard roles, default SA, token mounts): from platform
  components (Argo CD, Kyverno, RKE2 add-ons) that need broad rights. Tenant side is clean. Needs a per-component RBAC review.

## Key choices (why X, not Y)

- **RKE2 over kubeadm:** CIS profile, etcd encryption, audit log, PSA by default; fewer hand-made flags to get wrong.
- **Cilium over Calico:** L7 + FQDN policy, WireGuard, Hubble flow evidence in one component.
- **Kyverno (CEL ValidatingPolicy) over Gatekeeper:** policies readable as YAML, built-in PSS set, offline `kyverno test`.
- **Sealed Secrets over ESO:** no external secret store on Verda; ESO would need one. Key generated offline, backed up off-cluster.
- **ufw over Cilium host firewall:** Verda has no cloud firewall, so the host firewall must work before and without the cluster,
  and must not be editable by cluster-admin/Git. Cilium host policy is the next layer, not the replacement.

## Bonus items

| Bonus | Status | Where |
|---|---|---|
| Signing + verification | Done for podinfo (upstream keyless signature, pinned identity); nginx is unsigned upstream | `policies/verify-images.yaml` |
| CI gate | Done: policy tests, kubeconform, fixable-CRITICAL image scan; actions pinned by SHA | `.github/workflows/ci.yaml` |
| mTLS | **Skipped on purpose.** WireGuard already encrypts all pod traffic between nodes; the tenant boundary is identity-based network policy + admission, which mTLS would not change. Cilium mutual auth needs SPIRE (more moving parts than value here) | — |
| Attack simulation | 3 scenarios mapped to MITRE, controls, SOC signals | [attack scenarios](docs/attack-scenarios.md), demo §2–§10 |
| CVE triage | Runbook + worked example, applied (podinfo bump) | [CVE triage](docs/cve-triage.md) |
| Policy-as-code lifecycle | Git → tests → CI → Argo; Audit → Enforce rollout | README "Policy lifecycle" |
| Multi-tenancy A/B | 2 tenants, 2 tiers, isolation proven at network, RBAC, admission, GitOps | demo §10 |
| Scale write-up | Done | [scaling](docs/scale.md) |

## Gaps (honest) and next steps

1. Standard tier still shares the host kernel; untrusted tier (gVisor) has no runtime detection inside the sandbox.
2. Platform namespaces are not default-deny (they need per-component allows).
3. Signature verification covers podinfo only; next: internal registry that mirrors, scans and re-signs everything.
4. Custom API audit policy, shipped off-cluster with Falco events; today logs stay on cp-1.
5. SSH 22 still public on cp-1 (no console/SSM on Verda): Tailscale/Teleport for zero public ports.
6. Single control plane; long-lived admin cert instead of OIDC per person; AppProjects synced from Git.
7. Exfil through the one allowed external API is still possible (needs an egress proxy with path rules).
