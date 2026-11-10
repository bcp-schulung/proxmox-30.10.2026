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

variable "pve_ami_name" {
  type        = string
  description = "Name of the resulting Proxmox VE AMI"
}

variable "root_volume_size" {
  type        = number
  default     = 32
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

source "amazon-ebs" "pve" {
  region        = var.region
  source_ami    = var.base_ami
  instance_type = var.build_instance_type
  ami_name      = var.pve_ami_name

  # The boot volume is encrypted and enlarged - the Debian cloud image ships
  # with an 8 GiB unencrypted root volume, which is too small for Proxmox.
  encrypt_boot = true

  ssh_username         = "root"
  ssh_private_key_file = var.ssh_key_path
  ssh_timeout          = "20m"

  tags = {
    Name    = var.pve_ami_name
    LabTag  = "pve-advanced-seminar-lab"
    LabRole = "pve-ami"
  }

  run_tags = {
    Name    = "packer-build-pve"
    LabTag  = "pve-advanced-seminar-lab"
    LabRole = "pve-ami-build"
  }

  # The root volume of the Debian cloud image.
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # A scratch volume so the Proxmox installation never touches the root disk.
  launch_block_device_mappings {
    device_name           = "/dev/sdf"
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }
}

build {
  name    = "proxmox-ve"
  sources = ["source.amazon-ebs.pve"]

  # 1. Base packages and the cloud-init hardening.
  provisioner "shell" {
    script = "${path.root}/scripts/01-base.sh"
  }

  # 2. Add the Proxmox repository and install the Proxmox kernel.
  provisioner "shell" {
    script  = "${path.root}/scripts/10-proxmox-repo.sh"
    timeout = "30m"
  }

  # 3. Reboot into the Proxmox kernel. The connection drops on purpose -
  # expect_disconnect tells Packer that this is expected.
  provisioner "shell" {
    inline           = ["echo 'Rebooting into the Proxmox kernel...'", "systemctl reboot || true"]
    expect_disconnect = true
    timeout          = "20m"
  }

  # 4. Install the Proxmox VE packages.
  provisioner "shell" {
    script  = "${path.root}/scripts/20-proxmox-install.sh"
    timeout = "40m"
  }

  # 5. Kernel, initramfs, GRUB and cleanup.
  provisioner "shell" {
    script  = "${path.root}/scripts/30-pve-finalize.sh"
    timeout = "20m"
  }

  # 6. Prove the image boots and the Proxmox services come up.
  provisioner "shell" {
    inline  = [
      "uname -r",
      "pveversion -v | head -3",
      "systemctl is-active pveproxy pvedaemon pvestatd",
    ]
    timeout = "10m"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest-pve.json"
    strip_path = true
  }
}
