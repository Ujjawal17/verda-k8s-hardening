#!/usr/bin/env bash
# Turns 3 fresh Verda VMs into a hardened RKE2 cluster. Run once, right after `terraform apply`.
# Order matters: host hardening first (admin user, sshd, ufw), then RKE2 server, then agents.
# Only cp-1 accepts SSH from the internet; workers are reached through it (ProxyJump).
set -euo pipefail

RKE2_VERSION="v1.36.5+rke2r1"
ADMIN=admin
POD_CIDR="10.42.0.0/16"   # RKE2 default
DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)

# Node IPs from Terraform output. Map keys sort as cp-1, worker-1, worker-2.
mapfile -t IPS < <(terraform -chdir="$DIR/../infra" output -json node_ips | jq -r '.[]')
CP_IP="${IPS[0]}"
PUBKEY="$(cat ~/.ssh/verda_k8s.pub)"

jump() { [ "$1" = "$CP_IP" ] || echo "-J $ADMIN@$CP_IP"; }
# Run a command as root on a node, via the admin user + sudo.
on() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" $(jump "$ip") "$ADMIN@$ip" sudo "$@"; }

# 1. Host baseline. First login is the image's root user, which this step locks out.
harden_node() {
  local ip="$1" public_ssh="$2"
  echo ">> [$ip] hardening host (public ssh: $public_ssh)"
  # ssh joins args into one string for the remote shell: %q keeps the key (it has spaces) as one arg.
  ssh "${SSH_OPTS[@]}" $(jump "$ip") "root@$ip" bash -s -- \
      "$(printf '%q ' "$ip" "$public_ssh" "$ADMIN" "$PUBKEY" "$POD_CIDR" "${IPS[@]}")" <<'EOF'
set -euo pipefail
SELF="$1"; PUBLIC_SSH="$2"; ADMIN="$3"; PUBKEY="$4"; POD_CIDR="$5"; shift 5
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq ufw fail2ban >/dev/null

# The public IP must sit on an interface, otherwise node-ip in the RKE2 config is wrong.
ip -4 -o addr | grep -qw "$SELF" || { echo "public IP $SELF not on an interface (NAT?)"; exit 1; }

# Named admin user (key only, passwordless sudo is logged by sudo), root login off.
# Ubuntu ships a legacy "admin" group, so reuse it as the primary group when present.
getent group "$ADMIN" >/dev/null && GRP=(-g "$ADMIN") || GRP=(-U)
id "$ADMIN" >/dev/null 2>&1 || useradd -m -s /bin/bash "${GRP[@]}" -G sudo "$ADMIN"
install -d -m 700 -o "$ADMIN" -g "$ADMIN" "/home/$ADMIN/.ssh"
echo "$PUBKEY" | install -m 600 -o "$ADMIN" -g "$ADMIN" /dev/stdin "/home/$ADMIN/.ssh/authorized_keys"
echo "$ADMIN ALL=(ALL) NOPASSWD:ALL" | install -m 440 /dev/stdin "/etc/sudoers.d/90-$ADMIN"
# Lockout guard: never turn root login off unless admin has a valid key.
ssh-keygen -lf "/home/$ADMIN/.ssh/authorized_keys" >/dev/null || { echo "admin key invalid, not touching sshd"; exit 1; }

cat > /etc/ssh/sshd_config.d/10-hardening.conf <<CONF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers $ADMIN
X11Forwarding no
MaxAuthTries 3
CONF
sshd -t && systemctl reload ssh

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed            # pod traffic is filtered by Cilium policy, not ufw
[ "$PUBLIC_SSH" = yes ] && ufw allow 22/tcp     # cp-1 only; workers get SSH from cp-1 via the peer rule
for peer in "$@"; do ufw allow from "$peer"; done   # node-to-node: RKE2, etcd, kubelet, Cilium, SSH jump
ufw allow from "$POD_CIDR"          # pods -> host (e.g. Prometheus scraping node-exporter)
ufw --force enable
EOF
}

# 2. RKE2 install + CIS prerequisites (sysctls; etcd user on the server).
install_rke2() {
  local ip="$1" type="$2"
  echo ">> [$ip] installing RKE2 $type"
  on "$ip" bash -s -- "$RKE2_VERSION" "$type" <<'EOF'
set -euo pipefail
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$1" INSTALL_RKE2_TYPE="$2" sh -
cp /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
systemctl restart systemd-sysctl
if [ "$2" = server ]; then id etcd >/dev/null 2>&1 || useradd -r -c "etcd user" -s /sbin/nologin -M -U etcd; fi
mkdir -p /etc/rancher/rke2 /var/lib/rancher/rke2/server/manifests
EOF
}

push_config() {  # <ip> <template> <dest path>
  sed -e "s/__CP_IP__/$CP_IP/g" -e "s/__NODE_IP__/$1/g" "$DIR/$2" | on "$1" tee "$3" >/dev/null
}

kc() { on "$CP_IP" /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml "$@"; }

[ -f "$DIR/../.secrets/sealing.key" ] || { echo "run scripts/seal-secrets.sh first"; exit 1; }

# cp-1 first: workers are only reachable through it once it is hardened.
harden_node "$CP_IP" yes
for ip in "${IPS[@]:1}"; do harden_node "$ip" no; done

# 3. Control plane.
install_rke2 "$CP_IP" server
push_config "$CP_IP" rke2-server.yaml   /etc/rancher/rke2/config.yaml
push_config "$CP_IP" cilium-config.yaml /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml
push_config "$CP_IP" argocd.yaml        /var/lib/rancher/rke2/server/manifests/argocd.yaml
on "$CP_IP" systemctl enable --now rke2-server

# 4. Workers. Join token goes CP -> worker through stdin only.
for ip in "${IPS[@]:1}"; do
  install_rke2 "$ip" agent
  push_config "$ip" rke2-agent.yaml /etc/rancher/rke2/config.yaml
  on "$CP_IP" cat /var/lib/rancher/rke2/server/node-token \
    | on "$ip" install -m 600 /dev/stdin /etc/rancher/rke2/join-token
  on "$ip" systemctl enable --now rke2-agent
done

# 5. Our own Sealed Secrets key, in place before Argo CD starts the controller (scripts/seal-secrets.sh).
echo ">> installing sealed-secrets key"
{ kubectl create namespace sealed-secrets --dry-run=client -o yaml; echo "---"
  kubectl create secret tls sealed-secrets-key -n sealed-secrets --dry-run=client -o yaml \
      --cert="$DIR/../secrets/sealing-cert.pem" --key="$DIR/../.secrets/sealing.key" \
    | kubectl label --local -f - sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml
} | kc apply -f -

# 6. Hand over to GitOps: root app once Argo CD's CRDs exist. Everything else comes from Git.
echo ">> waiting for Argo CD"
until kc get crd applications.argoproj.io >/dev/null 2>&1; do sleep 10; done
kc apply -f - < "$DIR/root-app.yaml"

# 7. Kubeconfig for the laptop, pointed at the SSH tunnel (see README).
on "$CP_IP" cat /etc/rancher/rke2/rke2.yaml > "$DIR/../kubeconfig"
chmod 600 "$DIR/../kubeconfig"

echo ">> done"
echo ">> tunnel:  ssh -N -L 6443:127.0.0.1:6443 $ADMIN@$CP_IP"
echo ">> then:    KUBECONFIG=$(realpath "$DIR/../kubeconfig") kubectl get nodes -o wide"
