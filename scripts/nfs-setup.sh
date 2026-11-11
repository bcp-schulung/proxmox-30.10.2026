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

# The device may be given as a bare name ("nvme1n1") or as a full path
# ("/dev/nvme1n1"). The tools need the full path.
case "${DEVICE}" in
    /dev/*) ;;
    "")     echo "No device given" >&2; exit 1 ;;
    *)      DEVICE="/dev/${DEVICE}" ;;
esac

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

# The mount is retried.
#
# A freshly attached EBS volume shows up in the device list before udev
# has created the device node in /dev. The mount then fails with
#
#   fsconfig() failed: Can't lookup blockdev
#
# The device node appears a moment later, so the mount is tried again
# until it works.
mounted=0
for _ in $(seq 1 30); do
    if mountpoint -q /srv/nfs; then
        mounted=1
        break
    fi
    # The device is given explicitly instead of relying on the fstab
    # entry: the fstab entry refers to the device by name, and a name
    # that the kernel has not resolved yet makes the mount fail with
    # "Can't lookup blockdev".
    if [ -b "${DEVICE}" ] && mount -t ext4 "${DEVICE}" /srv/nfs 2>/dev/null; then
        mounted=1
        break
    fi
    sleep 2
done

if [ "${mounted}" != "1" ]; then
    echo "Could not mount ${DEVICE} on /srv/nfs" >&2
    mount /srv/nfs || true
    exit 1
fi

echo "${DEVICE} is mounted on /srv/nfs"

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
