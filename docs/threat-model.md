# Threat model

## System and trust boundaries

3 Verda VMs with public IPs and **no private network**: every node-to-node packet crosses the internet.
cp-1 runs etcd + API server (tainted, no workloads); 2 workers run the platform and one tenant app (`demo`).

Trust levels, highest first: **cluster admin** (holds the RKE2 admin kubeconfig) → **Git `main`** (Argo CD
applies it) → **platform namespaces** (security tooling, some need host access) → **tenant namespace** (untrusted code).

## Attackers considered

| Attacker | Starting point | Wants |
|---|---|---|
| Internet scanner / bot | Public IPs | Shell on a node, open API server, exposed dashboard |
| Compromised tenant app | Code exec in a `demo` pod (RCE, malicious dependency) | Lateral movement, cloud/node creds, other tenants, persistence |
| Malicious / careless deployer | Can commit to the repo's tenant path or create pods | Run privileged pods, untrusted images, loosen own fences |
| Supply chain | A pulled image or chart | Run code inside the cluster |

## Controls by layer

Each row: threat → control → where it's proven ([demo log](demo-log.md) section). **Gaps** are deliberate, see [summary](../SUMMARY.md).

| Layer | Threat | Control | Proof | Gap / residual risk |
|---|---|---|---|---|
| Node / host | SSH brute force, exposed node ports | ufw default-deny; only cp-1:22 public; key-only, `admin` user, root off, fail2ban; node ports only between node IPs | §1 nmap, sshd, ufw | 22 still public (dynamic home IP, Verda has no console/SSM). Prod: Tailscale/Teleport, zero public ports |
| Node / host | Workload lands next to etcd | cp-1 tainted `CriticalAddonsOnly:NoExecute` | §0 node list | Single control plane = availability risk |
| Control plane | API server reachable from internet | 6443 not public, kubectl via SSH tunnel | §1 nmap | Admin kubeconfig = long-lived cluster-admin client cert, no per-person identity (OIDC = prod) |
| Control plane | Undetected API abuse | RKE2 CIS profile audit log (default policy) | — | Default audit policy, logs stay on cp-1 (attacker with root can erase) |
| etcd / secrets | Secrets in Git or etcd in plaintext | Sealed Secrets (Git holds ciphertext); etcd encryption at rest | §8 | Encryption key on the same disk (no KMS on Verda); etcd snapshots on cp-1 unencrypted; sealing key copy on admin laptop |
| Pod / container | Privileged pod, host mounts, root, token theft | Kyverno PSS Restricted (fail-closed, 3 replicas) + PSA restricted as second layer; tenant rules: no SA token, read-only root FS, limits | §2 | Platform namespaces exempt by design (Falco, node-exporter, Trivy need host access) |
| Image / supply chain | `:latest`, mutable tags, untrusted publisher | No `:latest`; publisher-level allow-list; tenant images pinned by digest; Trivy continuous scanning | §2, §7 | No signature verification (cosign) yet; allow-listed publisher ≠ trusted image |
| Network | Lateral movement, exfiltration | Cilium default-deny (tenant ns), L7 GET-only frontend→backend, FQDN egress (`api.github.com` only) | §4 Hubble drops | Platform namespaces are not default-deny yet |
| Network | Cloud metadata / kubelet credential theft | Cluster-wide egress deny to 169.254.169.254 and kubelet 10250 | §4 | Verda metadata endpoint behaviour not documented; deny kept as defence in depth |
| Network | Sniffing node-to-node traffic on the internet | Cilium WireGuard (pod traffic); control-plane traffic is TLS | §4 encrypt status | — |
| GitOps | Tenant path loosens its own fences | `workloads` AppProject: own namespace only, no RBAC / quota / network policy / Kyverno kinds | §3 | AppProjects themselves synced from Git (a push to `main` could widen them); Git account = root of trust |
| Detection | Shell / recon in a running container | Falco (modern eBPF) + alerts `ShellSpawnedInContainer`, `ContainerContactedK8sApi` | §5, §6 | Falco events not shipped off-cluster |
| Detection | Policy probing, scanning, CVEs | Alerts on admission denials, policy-drop spikes, critical CVEs; Grafana "Security plane" dashboard | §6 | Alerts only in Alertmanager UI (no paging) |
| Sandbox | Kernel / runc escape from tenant code | — (shared kernel, runc) | — | gVisor/Kata RuntimeClass not deployed yet: biggest gap for untrusted code |
