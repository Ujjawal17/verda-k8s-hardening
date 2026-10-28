#!/usr/bin/env bash
# Offline secrets prep, no cluster needed:
# 1. Generate our own Sealed Secrets keypair (once). Private key stays in .secrets/ (gitignored, 0600);
#    bootstrap.sh installs it into the cluster. Public cert is committed so anyone can seal.
# 2. Seal the Grafana admin credentials with that public cert.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p .secrets

if [ ! -f .secrets/sealing.key ]; then
  openssl req -x509 -nodes -newkey rsa:4096 -days 365 -subj "/CN=sealed-secret/O=sealed-secret" \
    -keyout .secrets/sealing.key -out secrets/sealing-cert.pem 2>/dev/null
  echo "generated sealing keypair"
fi

[ -f .secrets/grafana-admin-password ] || openssl rand -base64 24 > .secrets/grafana-admin-password

kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin \
    --from-file=admin-password=.secrets/grafana-admin-password \
    --dry-run=client -o yaml \
  | kubeseal --cert secrets/sealing-cert.pem --scope strict -o yaml > monitoring/grafana-admin.sealed.yaml
echo "sealed monitoring/grafana-admin.sealed.yaml"
