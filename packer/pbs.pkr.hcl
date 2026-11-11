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

variable "ssh_keypair_name" {
  type        = string
  description = "Name of the EC2 key pair - without it the instance gets no key and SSH fails"
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "Subnet the build instance runs in - empty means the default VPC"
}

variable "build_instance_type" {
  type        = string
  default     = "m7i.2xlarge"
  description = "Instance type used while building the AMI"
}

source "amazon-ebs" "pbs" {
  region        = var.region
  source_ami    = var.base_ami
  instance_type = var.build_instance_type
  ami_name      = var.pbs_ami_name

  encrypt_boot = true

  # Pin the build to the lab VPC when one exists.
  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  ssh_username         = "admin"
  ssh_private_key_file = var.ssh_key_path
  ssh_keypair_name     = var.ssh_keypair_name
  ssh_timeout          = "20m"

  # The build instance needs a public address to reach the package mirrors.
  associate_public_ip_address = true

  tags = {
    Name    = var.pbs_ami_name
    LabTag  = "pve-advanced-seminar-lab"
    LabRole = "pbs-ami"
  }

  run_tags = {
    Name    = "packer-build-pbs"
    LabTag  = "pve-advanced-seminar-lab"
    LabRole = "pbs-ami-build"
  }

  # The root volume of the Debian cloud image.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }
}

build {
  name    = "proxmox-backup-server"
  sources = ["source.amazon-ebs.pbs"]

  # The shared helpers are uploaded next to the build scripts. Packer runs
  # a script from /tmp, so the scripts cannot find the helpers through
  # BASH_SOURCE.
  provisioner "shell" {
    inline = ["mkdir -p /tmp/pve-build"]
  }

  provisioner "file" {
    source      = "${path.root}/scripts/lib-common.sh"
    destination = "/tmp/pve-build/lib-common.sh"
  }

  provisioner "shell" {
    script           = "${path.root}/scripts/01-base.sh"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }

  # The SSM agent, so that the PBS instance is reachable from a CGNAT
  # network where the public IPv4 address does not work.
  provisioner "shell" {
    script           = "${path.root}/scripts/05-ssm-agent.sh"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }

  provisioner "shell" {
    script           = "${path.root}/scripts/40-pbs-install.sh"
    timeout          = "45m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }

  provisioner "shell" {
    inline = [
      "sudo proxmox-backup-manager versions",
      "sudo systemctl is-active proxmox-backup.service",
      "systemctl is-enabled amazon-ssm-agent || systemctl is-enabled ssm-agent",
    ]
    timeout = "15m"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest-pbs.json"
    strip_path = true
  }
}
