#!/bin/bash
# =============================================================================
# pbs-setup.sh - configure the Proxmox Backup Server for the seminar lab
# =============================================================================
# Usage: pbs-setup.sh <device> <datastore-name> <backup-user> <password>
# =============================================================================
set -euo pipefail

DEVICE="${1:?device required}"
DATASTORE="${2:?datastore name required}"
BACKUP_USER="${3:?backup user required}"
PASSWORD="${4:?password required}"

# The device may be given as a bare name ("nvme1n1") or as a full path
# ("/dev/nvme1n1"). The tools need the full path.
case "${DEVICE}" in
    /dev/*) ;;
    "")     echo "No device given" >&2; exit 1 ;;
    *)      DEVICE="/dev/${DEVICE}" ;;
esac

export DEBIAN_FRONTEND=noninteractive

# --- the datastore volume --------------------------------------------------
if ! blkid "${DEVICE}" >/dev/null 2>&1; then
    echo "Formatting ${DEVICE} as ext4"
    mkfs.ext4 -F -m 0 "${DEVICE}"
fi

mkdir -p /var/lib/proxmox-backup
if ! grep -q '^/var/lib/proxmox-backup ' /etc/fstab; then
    printf '/var/lib/proxmox-backup %s ext4 defaults,nofail 0 2\n' "${DEVICE}" >> /etc/fstab
fi
# The mount is retried: a freshly attached EBS volume shows up in the
# device list before udev has created the device node in /dev, and the
# mount then fails with "Can't lookup blockdev".
mounted=0
for _ in $(seq 1 30); do
    if mountpoint -q /var/lib/proxmox-backup; then
        mounted=1
        break
    fi
    if [ -b "${DEVICE}" ] && mount -t ext4 "${DEVICE}" /var/lib/proxmox-backup 2>/dev/null; then
        mounted=1
        break
    fi
    sleep 2
done

if [ "${mounted}" != "1" ]; then
    echo "Could not mount ${DEVICE} on /var/lib/proxmox-backup" >&2
    exit 1
fi

echo "${DEVICE} is mounted on /var/lib/proxmox-backup"

# --- the root password -----------------------------------------------------
echo "root:${PASSWORD}" | chpasswd

# --- the datastore ---------------------------------------------------------
mkdir -p "/var/lib/proxmox-backup/datastore"

# --- the backup user -------------------------------------------------------
# The API is used because 'proxmox-backup-manager user password set' needs a
# terminal. The root password was set above, so the API accepts it.
if ! proxmox-backup-manager user list 2>/dev/null | grep -q "${BACKUP_USER}"; then
    curl -ksS -u "root:${PASSWORD}" -X POST 'https://127.0.0.1:8007/api2/json/access/users' \
        --data-urlencode "userid=${BACKUP_USER}" \
        --data-urlencode "password=${PASSWORD}" \
        --data-urlencode 'comment=Proxmox seminar lab backup user' >/dev/null
    echo "Created the backup user ${BACKUP_USER}"
fi

if ! proxmox-backup-manager datastore list 2>/dev/null | grep -q "${DATASTORE}"; then
    proxmox-backup-manager datastore create "${DATASTORE}" /var/lib/proxmox-backup/datastore \
        2>/dev/null || \
    curl -ksS -u "root:${PASSWORD}" -X POST 'https://127.0.0.1:8007/api2/json/datastore' \
        --data-urlencode "name=${DATASTORE}" \
        --data-urlencode 'path=/var/lib/proxmox-backup/datastore' >/dev/null
    echo "Created the datastore ${DATASTORE}"
fi

systemctl enable proxmox-backup.service proxmox-backup-proxy.service
systemctl restart proxmox-backup.service proxmox-backup-proxy.service

echo "PBS is ready"
proxmox-backup-manager datastore list
proxmox-backup-manager fingerprint
