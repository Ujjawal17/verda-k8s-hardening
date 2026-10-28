# VMs only. Cluster bootstrap (ufw, RKE2, Cilium, Argo CD) is done by scripts/bootstrap.sh
# over SSH, so the RKE2 join token never lands in Terraform state.

provider "verda" {} # creds from VERDA_CLIENT_ID / VERDA_CLIENT_SECRET

resource "verda_ssh_key" "admin" {
  name       = "verda-k8s-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "verda_instance" "node" {
  for_each = toset(var.nodes)

  hostname      = each.key
  description   = "verda-k8s-hardening ${each.key}"
  instance_type = var.instance_type
  image         = var.image
  location      = var.location
  ssh_key_ids   = [verda_ssh_key.admin.id]
}
