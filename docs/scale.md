# Scaling this design

This repo is one cluster with two tenants. What changes when it becomes a product with hundreds of tenants
and clusters (managed Kubernetes on Verda)?

## What carries over unchanged

- **Policies as code, tested in CI** (`policies/`, `tests/kyverno/`): the same ValidatingPolicies ship to every cluster.
- **Tenancy as a template** (`tenancy/<tenant>/`): namespace + quota + limits + default-deny + RBAC + AppProject.
- **Secure by default**: cluster-wide default-deny, namespace guard, image rules apply to new namespaces with no opt-in.
- **Tiers**: standard (runc + Falco) vs untrusted (gVisor), selected by a platform-owned namespace label.

## What has to change

| Area | Here | At scale |
|---|---|---|
| Control plane | 1 server node, etcd on it | 3+ servers (or managed), etcd on dedicated nodes, encrypted off-site snapshots, KMS for secret encryption |
| Tenant boundary | Namespace per tenant, shared nodes | Namespace for trusted teams; **dedicated node pools** (taints + Kyverno-enforced tolerations/nodeSelector) for untrusted; **cluster per tenant** (vCluster or real) where tenants need cluster-admin or GPU isolation |
| Fleet GitOps | One Argo CD, app-of-apps | Argo CD ApplicationSets (cluster generator) or one Argo per region; tenant onboarding = one PR generating the tenancy template |
| Policy rollout | Enforce immediately | Ring rollout: Audit on canary clusters → PolicyReports reviewed → Enforce fleet-wide; policy versions pinned per ring |
| Identity | Admin client cert, impersonated groups | OIDC (per person, MFA), groups from the IdP drive the per-tenant RoleBindings; short-lived kubeconfigs |
| Access | SSH to cp-1, tunnel | No public SSH: Tailscale/Teleport, audited sessions; API behind private LB + IP allow-lists |
| Detection | Prometheus + Alertmanager on the cluster | Falco/audit/Hubble events shipped to a central SIEM; per-tenant alert routing; detections as code with tests |
| Supply chain | Verify upstream signature for podinfo | Internal registry (Harbor) as the only allowed source: mirror + scan + **re-sign** at ingestion; Kyverno verifies the platform's key everywhere; SBOM attestations |
| Vulnerability mgmt | Trivy Operator per cluster | Central aggregation of VulnerabilityReports, SLA tracking (`docs/cve-triage.md`), CI gate on every tenant repo |
| GPU tenants | — | GPU nodes in dedicated pools, no MIG sharing across tenants unless the tier allows it, device plugin and driver versions under policy; gVisor GPU support (nvproxy) evaluated per driver |
| Cost of controls | gVisor overhead per tenant-b pod | Measure; sandbox only the untrusted tier, keep runc + Falco for trusted workloads |

## Limits I would flag

- Kyverno with `failurePolicy: Fail` is on the critical path of every pod create: keep 3+ replicas, a PDB, and
  monitor webhook latency; an outage blocks deploys fleet-wide if rollouts are not ringed.
- Per-cluster Falco + Hubble metrics cardinality grows with tenants: aggregate centrally, keep per-rule counters.
- Namespace-level tenancy is not a hard boundary against kernel bugs on shared nodes; that is what the gVisor tier
  and dedicated node pools are for.
