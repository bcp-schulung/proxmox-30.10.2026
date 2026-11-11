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

source "amazon-ebs" "pve" {
  region        = var.region
  source_ami    = var.base_ami
  instance_type = var.build_instance_type
  ami_name      = var.pve_ami_name

  # The boot volume is encrypted and enlarged - the Debian cloud image ships
  # with an 8 GiB unencrypted root volume, which is too small for Proxmox.
  encrypt_boot = true

  # Pin the build to the lab VPC when one exists.
  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  ssh_username         = "admin"
  ssh_private_key_file = var.ssh_key_path
  ssh_keypair_name     = var.ssh_keypair_name

  # The build runs over the public internet and the connection occasionally
  # drops during the long package downloads. A generous timeout keeps a
  # transient drop from killing the whole build.
  ssh_timeout = "30m"

  # The build instance needs a public address to reach the package mirrors.
  associate_public_ip_address = true

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

  provisioner "file" {
    source      = "${path.root}/scripts/gate.sh"
    destination = "/tmp/pve-build/gate.sh"
  }

  # 1. Base packages and the cloud-init hardening.
  provisioner "shell" {
    script           = "${path.root}/scripts/01-base.sh"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }

  # 2. The SSM agent. It is baked into the AMI so that the instance can be
  #    reached from a CGNAT network, where the public IPv4 address is
  #    unreachable and no inbound SSH is possible.
  provisioner "shell" {
    script           = "${path.root}/scripts/05-ssm-agent.sh"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }

  # 3. Add the Proxmox repository and install the Proxmox kernel.
  provisioner "shell" {
    script           = "${path.root}/scripts/10-proxmox-repo.sh"
    timeout          = "10m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }



  # Wait for the kernel install - attempt 1 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 2 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 3 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 4 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 5 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 6 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 7 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 8 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 9 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 10 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 11 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the kernel install - attempt 12 of 12.
  provisioner "shell" {
    script           = "${path.root}/scripts/10b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # The kernel install must have finished before the reboot.
  provisioner "shell" {
    inline = [
      "if sudo test -s '/var/log/pve-kernel.rc'; then rc=$(sudo cat '/var/log/pve-kernel.rc'); if [ \"$rc\" = \"0\" ]; then echo 'OK: /var/log/pve-kernel.rc reports success'; else echo 'ERROR: /var/log/pve-kernel.rc reports exit status ' \"$rc\"; sudo tail -40 '/var/log/pve-kernel.log'; exit 1; fi; else echo 'ERROR: /var/log/pve-kernel.rc is missing - the detached work did not finish'; sudo tail -40 '/var/log/pve-kernel.log'; exit 1; fi",
    ]
    timeout = "5m"
  }
  # 5. Reboot into the Proxmox kernel. The connection drops on purpose -
  #    expect_disconnect tells Packer that this is expected.
  provisioner "shell" {
    inline            = ["echo 'Rebooting into the Proxmox kernel...'", "sudo systemctl reboot || true"]
    expect_disconnect = true
    timeout           = "20m"
  }

  # The reboot clears /tmp, so the helper scripts are uploaded again.
  provisioner "shell" {
    inline = ["mkdir -p /tmp/pve-build"]
  }

  provisioner "file" {
    source      = "${path.root}/scripts/lib-common.sh"
    destination = "/tmp/pve-build/lib-common.sh"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/gate.sh"
    destination = "/tmp/pve-build/gate.sh"
  }

  # 6. Install the Proxmox VE packages.
  provisioner "shell" {
    script           = "${path.root}/scripts/20-proxmox-install.sh"
    timeout          = "10m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }



  # Wait for the package install - attempt 1 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 2 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 3 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 4 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 5 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 6 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 7 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 8 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 9 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 10 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 11 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 12 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 13 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 14 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the package install - attempt 15 of 15.
  provisioner "shell" {
    script           = "${path.root}/scripts/20b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # The package install must have finished before the finalize step.
  provisioner "shell" {
    inline = [
      "if sudo test -s '/var/log/pve-install.rc'; then rc=$(sudo cat '/var/log/pve-install.rc'); if [ \"$rc\" = \"0\" ]; then echo 'OK: /var/log/pve-install.rc reports success'; else echo 'ERROR: /var/log/pve-install.rc reports exit status ' \"$rc\"; sudo tail -40 '/var/log/pve-install.log'; exit 1; fi; else echo 'ERROR: /var/log/pve-install.rc is missing - the detached work did not finish'; sudo tail -40 '/var/log/pve-install.log'; exit 1; fi",
    ]
    timeout = "5m"
  }
  # 8. Kernel, initramfs, GRUB and cleanup.
  provisioner "shell" {
    script           = "${path.root}/scripts/30-pve-finalize.sh"
    timeout          = "10m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build"]
  }



  # Wait for the finalize step - attempt 1 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 2 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 3 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 4 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 5 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 6 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 7 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # Wait for the finalize step - attempt 8 of 8.
  provisioner "shell" {
    script           = "${path.root}/scripts/30b-proxmox-wait.sh"
    timeout          = "3m"
    environment_vars = ["PACKER_SCRIPTS_DIR=/tmp/pve-build", "WAIT_INTERVAL=90"]
  }

  # The finalize step must have finished before the verification.
  provisioner "shell" {
    inline = [
      "if sudo test -s '/var/log/pve-finalize.rc'; then rc=$(sudo cat '/var/log/pve-finalize.rc'); if [ \"$rc\" = \"0\" ]; then echo 'OK: /var/log/pve-finalize.rc reports success'; else echo 'ERROR: /var/log/pve-finalize.rc reports exit status ' \"$rc\"; sudo tail -40 '/var/log/pve-finalize.log'; exit 1; fi; else echo 'ERROR: /var/log/pve-finalize.rc is missing - the detached work did not finish'; sudo tail -40 '/var/log/pve-finalize.log'; exit 1; fi",
    ]
    timeout = "5m"
  }
  # 10. Prove the image boots and the Proxmox services come up, and that
  #    the DNS and firewall fixes are in place.
  provisioner "shell" {
    inline = [
      "uname -r",
      "pveversion -v | head -3",
      "systemctl is-active pveproxy pvedaemon pvestatd",
      "systemctl is-enabled amazon-ssm-agent || systemctl is-enabled ssm-agent",
      "getent hosts s3.eu-central-1.amazonaws.com >/dev/null && echo DNS-OK",
      "grep -l 'policy_in' /etc/pve/nodes/*/host.fw && echo FIREWALL-OK",
    ]
    timeout = "15m"
  }

  post-processor "manifest" {
    output     = "${path.root}/manifest-pve.json"
    strip_path = true
  }
}
