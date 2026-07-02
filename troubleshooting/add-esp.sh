#!/bin/bash
# =============================================================================
# add-esp.sh — FIX for: "I cloned my rootfs to the NVMe, but on removing the SD
# card the board drops into the UEFI shell / boot menu."
#
# Cause: your NVMe has only ONE big ext4 partition and no EFI System Partition,
# so UEFI has no FAT partition to load \EFI\BOOT\BOOTAA64.efi from.
#
# This shrinks your existing rootfs by ~1GB and adds a proper ESP at the end,
# WITHOUT re-cloning. Your data is preserved. Run from the SD system with sudo.
#
# (If you use clone-sd-to-nvme.sh you do NOT need this — it makes the ESP itself.)
# =============================================================================
set -eu

NVME_DISK="${1:-/dev/nvme0n1}"
APP_PART="${NVME_DISK}p1"
ESP_PART="${NVME_DISK}p2"
ESPMNT=/mnt/nvme-esp
SHRINK_TO_GB=999          # new end (in GB) of the rootfs partition on a ~1TB disk
say(){ echo -e "\n\033[1;36m==> $*\033[0m"; }
die(){ echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "run with sudo"
command -v mkfs.vfat >/dev/null || { apt-get update && apt-get install -y dosfstools; }
mountpoint -q /boot/efi || die "/boot/efi not mounted; can't find BOOTAA64.efi"

for m in "$APP_PART" "$ESP_PART" "$ESPMNT" /mnt/chk; do umount "$m" 2>/dev/null || true; done

say "current layout"; parted "$NVME_DISK" print

say "[1/6] fsck the rootfs"
e2fsck -f -y "$APP_PART"

say "[2/6] shrink the FILESYSTEM first (safe: only meta+used blocks move)"
resize2fs "$APP_PART" 100G          # 100 GiB, far above typical usage

say "[3/6] shrink the PARTITION end to ${SHRINK_TO_GB}GB (start unchanged -> data safe)"
# parted --script mis-handles the shrink warning; feed 'Yes' via ---pretend-input-tty
echo Yes | parted ---pretend-input-tty "$NVME_DISK" resizepart 1 "${SHRINK_TO_GB}GB"
partprobe "$NVME_DISK"; sleep 2
end1="$(parted -m "$NVME_DISK" unit GB print | awk -F: '/^1:/{print $3}')"
[ "$end1" != "1000GB" ] || die "partition did not shrink; run 'sudo parted $NVME_DISK' -> resizepart 1 ${SHRINK_TO_GB}GB -> Yes, then re-run."

say "[4/6] grow the filesystem back to fill the shrunk partition"
resize2fs "$APP_PART"

say "[5/6] create + format the ESP, flag it"
parted -s "$NVME_DISK" mkpart esp fat32 "${SHRINK_TO_GB}GB" 100%
parted -s "$NVME_DISK" set 2 esp on
parted -s "$NVME_DISK" set 2 boot on
partprobe "$NVME_DISK"; sleep 2
mkfs.vfat -F 32 -n ESP "$ESP_PART"

say "[6/6] copy the UEFI loader into the new ESP"
mkdir -p "$ESPMNT"; mount "$ESP_PART" "$ESPMNT"
cp -r /boot/efi/EFI "$ESPMNT"/
sync; find "$ESPMNT" -maxdepth 3 | sed 's/^/    /'; umount "$ESPMNT"

say "final layout"; parted "$NVME_DISK" print
echo -e "\nDone. If you STILL get 'nvme0n1p1 not found' at boot, run fix-initrd.sh next."
