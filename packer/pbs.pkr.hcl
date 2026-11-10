packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type        = string
  description = "AWS region the AMI is built in"
}

variable "base_ami" {
  type        = string
  description = "Debian 13 cloud image used as the base"
}

variable "pbs_ami_name" {
  type        = string
  description = "Name of the resulting Proxmox Backup Server AMI"
}

variable "root_volume_size" {
  type        = number
  default     = 16
  description = "Size of the AMI root volume in GiB"
}

variable "ssh_key_path" {
  type        = string
  description = "Path to the private key used for the build instance"
}

variable "build_instance_type" {
  type        = string
  default     = "m8i.4xlarge"
  description = "Instance type used while building the AMI"
}

source "amazon-ebs" "pbs" {
  region        = var.region
  source_ami    = var.base_ami
  instance_type = var.build_instance_type
  ami_name      = var.pbs_ami_name

  root_volume_type = "gp3"
  root_volume_size = var.root_volume_size
  encrypt_boot     = true

  ssh_username         = "root"
  ssh_private_key_file = var.ssh_key_path
  ssh_timeout          = "20m"

  tags = {
    Name   = var.pbs_ami_name
    LabTag = "pve-advanced-seminar-lab"
    LabRole = "pbs-ami"
  }

  run_tags = {
    Name    = "packer-build-pbs"
    LabTag  = "pve-advanced-seminar-lab"
    LabRole = "pbs-ami-build"
  }
}

build {
  name    = "proxmox-backup-server"
  sources = ["source.amazon-ebs.pbs"]

  provisioner "shell" {
    label = "base"
    script = "${path.root}/packer/scripts/01-base.sh"
  }

  provisioner "shell" {
    label   = "pbs-install"
    script  = "${path.root}/packer/scripts/40-pbs-install.sh"
    timeout = "30m"
  }

  provisioner "shell" {
    label = "verify"
    inline = [
      "proxmox-backup-manager versions",
      "systemctl is-active proxmox-backup.service proxmox-backup-proxy.service",
    ]
    timeout = "10m"
  }

  post-processor "manifest" {
    output     = "${path.root}/packer/manifest-pbs.json"
    strip_path = true
  }
}
