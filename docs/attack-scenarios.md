# Attack simulation

Three attacker paths, run against the live cluster by `scripts/demo.sh`. Each step: what the attacker tries,
which control stops it, and what the SOC sees. Evidence = section of the [demo log](demo-log.md).

## Scenario 1 — RCE in a tenant app → credentials → lateral movement

Attacker has code execution in `demo/frontend` (e.g. a dependency RCE). MITRE: T1059, T1552, T1613, T1046.

| Step | Attempt | Control | Result | SOC sees | Evidence |
|---|---|---|---|---|---|
| 1 | Interactive shell | — (allowed: it is the foothold) | Shell runs | **`ShellSpawnedInContainer`** (critical) | §5, §6 |
| 2 | Read SA token from `/var/run/secrets` | Kyverno: `automountServiceAccountToken: false` | No token in pod | — | §2, §8 |
| 3 | Cloud metadata `169.254.169.254` | Cilium cluster-wide egress deny | Dropped | Hubble drop, `NetworkPolicyDropsSpike` | §4 |
| 4 | Kubelet `:10250/pods` on a node | Cilium cluster-wide egress deny | Dropped | Hubble drop | §4 |
| 5 | API server `10.43.0.1:443` | Default-deny (tenant + cluster-wide) | Dropped | Hubble drop; Falco API rule as backup | §4 |
| 6 | Pivot to tenant-b | Default-deny both sides | Dropped | Hubble drop | §10 |
| 7 | Write a tool to disk | Read-only root FS | Fails | — | §2 |

## Scenario 2 — Data exfiltration from the backend

Attacker controls `demo/backend`, which legitimately calls one external API. MITRE: T1048, T1071.004.

| Step | Attempt | Control | Result | SOC sees | Evidence |
|---|---|---|---|---|---|
| 1 | HTTPS to own server (`example.com`) | FQDN egress allow-list (`api.github.com` only) | Dropped | Hubble drop | §4 |
| 2 | DNS tunnelling: `<data>.exfil.example.com` | Cilium DNS proxy, only `**.cluster.local` + `api.github.com` resolve | `REFUSED` | Hubble DNS verdict | §4 |
| 3 | Frontend writes data via backend (`POST`) | L7 policy: GET only | `403` from Cilium proxy | Hubble L7 flow | §4 |
| 4 | Residual | Exfil through `api.github.com` itself (e.g. gist) | **Possible** | Not detected | — |

Residual risk 4: an allowed SaaS endpoint is an exfil channel. Mitigation: egress via a proxy with URL/path rules or
egress gateway + logging; outside this build.

## Scenario 3 — Malicious tenant / poisoned supply chain

Attacker is a tenant developer (or controls a commit to a tenant path, or a registry account). MITRE: T1610, T1611, T1195.

| Step | Attempt | Control | Result | Evidence |
|---|---|---|---|---|
| 1 | Privileged pod / hostPath | PSA restricted + Kyverno PSS | Denied (PSA first, Kyverno second) | §2 |
| 2 | Untrusted registry, `:latest` | Kyverno allow-list, tag rule | Denied | §2 |
| 3 | Image from an allow-listed publisher but **unsigned / tampered** | Kyverno `verify-image-signatures` (pinned keyless identity) | Denied | §2 |
| 4 | Drop gVisor in the untrusted tier | Kyverno `require-sandbox` | Denied | §10 |
| 5 | Relax own namespace (PSA `privileged`, remove sandbox label) | RBAC (no namespace rights) + Kyverno `namespace-guard` | Denied | §10 |
| 6 | Delete own default-deny / grant self RBAC | RBAC `tenant-developer` (no netpol/RBAC verbs) + AppProject blacklist | Denied | §3, §10 |
| 7 | Deploy into another tenant via Argo CD | AppProject destination = own namespace only | Refused | §10 |
| 8 | Kernel exploit from untrusted code | gVisor (user-space kernel) for tenant-b | Contained in sandbox; **Falco blind inside gVisor** | §10 |

## Detection requirements for the SOC (derived)

| Signal | Source | Alert | Response |
|---|---|---|---|
| Shell in a workload container | Falco | `ShellSpawnedInContainer` (critical) | Isolate pod (label → quarantine policy), capture, rotate app secrets |
| Pod contacts API server | Falco | `ContainerContactedK8sApi` | Network policy was bypassed or missing: treat as P1 |
| Burst of policy drops | Hubble | `NetworkPolicyDropsSpike` | Check source pod: probing vs broken deploy |
| Admission denials | Kyverno | `AdmissionRequestsDenied` | One = mistake, burst = probing; check who (audit log) |
| Critical CVE running | Trivy | `CriticalVulnerabilityRunning` | `docs/cve-triage.md` |
| Gaps | — | API audit events (RBAC probing, `exec`, secret reads) are not shipped or alerted yet; nothing inside gVisor | Next step: audit policy + off-cluster SIEM; gVisor runtime monitoring |
