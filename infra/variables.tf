variable "nodes" {
  description = "Hostnames. First one is the RKE2 server (control plane), the rest are agents."
  type        = list(string)
  default     = ["cp-1", "worker-1", "worker-2"]
}

variable "instance_type" {
  type    = string
  default = "CPU.4V.16G" # 4 vCPU / 16 GB, ~0.048 USD/h
}

variable "image" {
  type    = string
  default = "24.04.base" # Ubuntu 24.04 minimal (image_type from GET /v1/images)
}

variable "location" {
  type    = string
  default = "FIN-01"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/verda_k8s.pub"
}
