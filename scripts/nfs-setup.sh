#!/bin/bash
# =============================================================================
# nfs-setup.sh - configure the NFS server for the seminar lab
# =============================================================================
# Usage: nfs-setup.sh <device> <export-path>
#
# The export path is what NFS clients mount (e.g. /export/lab). On disk it
# lives under /srv/nfs, which is the mount point of the dedicated EBS volume.
# =============================================================================
set -euo pipefail

DEVICE="${1:?device required}"
EXPORT_PATH="${2:?export path required}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq nfs-kernel-server rsync

# --- the data volume -------------------------------------------------------
if ! blkid "${DEVICE}" >/dev/null 2>&1; then
    echo "Formatting ${DEVICE} as ext4"
    mkfs.ext4 -F -m 0 "${DEVICE}"
fi

mkdir -p /srv/nfs
if ! grep -q '^/srv/nfs ' /etc/fstab; then
    printf '/srv/nfs %s ext4 defaults,nofail 0 2\n' "${DEVICE}" >> /etc/fstab
fi
mountpoint -q /srv/nfs || mount /srv/nfs

# --- the export ------------------------------------------------------------
# The data directory structure mirrors what Proxmox expects from a storage
# definition with content=images,rootdir,iso,vztmpl,backup,snippets.
mkdir -p "/srv/nfs${EXPORT_PATH}"/{images,rootfs,iso,vztmpl,backup,snippets}
chmod -R 777 "/srv/nfs${EXPORT_PATH}"

cat > /etc/exports << EOF
# Proxmox seminar lab - NFS export
# fsid=0 makes /srv/nfs the NFSv4 pseudo root, so clients can mount
# server:${EXPORT_PATH} directly. no_root_squash is required for the
# unprivileged LXC containers whose rootfs lives here.
/srv/nfs *(rw,sync,no_root_squash,no_subtree_check,fsid=0,crossmnt,async,insecure)
EOF

exportfs -ra
systemctl enable nfs-server 2>/dev/null || true
systemctl restart nfs-server

echo "NFS export ${EXPORT_PATH} is live"
exportfs -v
