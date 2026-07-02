#!/bin/bash
# =============================================================================
# clone-sd-to-nvme.sh
#
# Migrate a *running* NVIDIA Jetson Orin Nano system (JetPack 6 / L4T R36)
# from the microSD card to an NVMe SSD — entirely on the board.
# No host PC, no SDK Manager, no re-flashing.
#
# It does all THREE things a working NVMe boot needs (most tutorials miss 2 & 3):
#   1. Clone the rootfs           (partition + mkfs + rsync)
#   2. Create an ESP on the NVMe  (FAT32 + BOOTAA64.efi) so UEFI can boot it
#   3. Rebuild the initrd with the NVMe + Tegra-PCIe drivers so the kernel
#      can find root=/dev/nvme0n1p1 early in boot
#
# USAGE (run from the SD system):
#   sudo ./clone-sd-to-nvme.sh
#   sudo poweroff ; remove the SD card ; power on -> boots from NVMe
#
# WARNING: This ERASES the target NVMe disk. Your SD card is left untouched
#          and remains a working fallback.
# =============================================================================
set -euo pipefail

# ---- tunables ---------------------------------------------------------------
ESP_SIZE="1GiB"          # size of the EFI System Partition to create on the NVMe
MNT=/mnt/nvme            # temp mountpoint for the NVMe rootfs
ESPMNT=/mnt/nvme-esp     # temp mountpoint for the NVMe ESP
LOG=/var/log/clone-sd-to-nvme.log

# ---- helpers ----------------------------------------------------------------
say()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
die()  { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

exec > >(tee -a "$LOG") 2>&1
[ "$EUID" -eq 0 ] || die "please run with sudo."

# ---- detect devices ---------------------------------------------------------
KREL="$(uname -r)"
CUR_ROOT="$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')"     # e.g. /dev/mmcblk0p1
NVME_DISK="$(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /nvme/ {print $1; exit}')"
[ -n "${NVME_DISK:-}" ] || die "no NVMe disk found."
APP_PART="${NVME_DISK}p1"
ESP_PART="${NVME_DISK}p2"

say "Environment"
echo "  kernel        : $KREL"
echo "  current root  : $CUR_ROOT"
echo "  target NVMe   : $NVME_DISK  ($(lsblk -dno SIZE "$NVME_DISK"))"

# ---- sanity checks ----------------------------------------------------------
case "$CUR_ROOT" in
  *nvme*) die "you are ALREADY booted from NVMe ($CUR_ROOT). Nothing to do." ;;
esac
[ -b "$NVME_DISK" ] || die "$NVME_DISK is not a block device."
mountpoint -q /boot/efi || die "/boot/efi is not mounted; cannot locate BOOTAA64.efi (the L4T UEFI loader)."
[ -f /boot/efi/EFI/BOOT/BOOTAA64.efi ] || die "BOOTAA64.efi not found under /boot/efi."
command -v rsync       >/dev/null || die "rsync not installed (sudo apt install rsync)."
command -v mkfs.vfat   >/dev/null || { say "installing dosfstools"; apt-get update && apt-get install -y dosfstools; }

# ---- confirm ----------------------------------------------------------------
echo
echo -e "\033[1;33m>>> This will COMPLETELY ERASE $NVME_DISK.\033[0m"
read -rp ">>> Type YES to continue: " ans
[ "$ans" = "YES" ] || die "aborted, nothing changed."

# =============================================================================
say "[1/8] Partition the NVMe  (p1 = APP/rootfs, p2 = ESP)"
for m in "$APP_PART" "$ESP_PART" "$MNT" "$ESPMNT"; do umount "$m" 2>/dev/null || true; done
parted -s "$NVME_DISK" mklabel gpt
parted -s "$NVME_DISK" mkpart APP ext4  1MiB "-$ESP_SIZE"
parted -s "$NVME_DISK" mkpart ESP fat32 "-$ESP_SIZE" 100%
parted -s "$NVME_DISK" set 2 esp on
parted -s "$NVME_DISK" set 2 boot on
partprobe "$NVME_DISK"; sleep 2

say "[2/8] Create filesystems"
mkfs.ext4 -F -L APP "$APP_PART"
mkfs.vfat -F 32 -n ESP "$ESP_PART"

say "[3/8] rsync the running rootfs -> NVMe  (this takes several minutes)"
mkdir -p "$MNT"; mount "$APP_PART" "$MNT"
rsync -aAXH --info=progress2 \
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* \
  --exclude=/tmp/* --exclude=/run/* --exclude=/mnt/* \
  --exclude=/media/* --exclude="/lost+found" \
  --exclude="$MNT" --exclude="$ESPMNT" \
  / "$MNT/"
mkdir -p "$MNT"/{dev,proc,sys,tmp,run,mnt,media}
chmod 1777 "$MNT/tmp"

say "[4/8] Populate the NVMe ESP with the UEFI loader (BOOTAA64.efi)"
mkdir -p "$ESPMNT"; mount "$ESP_PART" "$ESPMNT"
cp -r /boot/efi/EFI "$ESPMNT"/
sync; umount "$ESPMNT"

say "[5/8] Point extlinux.conf at the NVMe root"
CONF="$MNT/boot/extlinux/extlinux.conf"
cp -a "$CONF" "$CONF.sd.bak"
sed -i -E "s#root=[^ ]+#root=$APP_PART#g" "$CONF"
grep -m1 'APPEND .*root=' "$CONF" | sed 's/^/    /'

say "[6/8] Fix /etc/fstab on the NVMe (mount the NVMe's own ESP, nofail)"
FSTAB="$MNT/etc/fstab"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"
cp -a "$FSTAB" "$FSTAB.sd.bak"
sed -i -E 's#^([^#].*[[:space:]]/boot/efi[[:space:]])#\##' "$FSTAB"   # disable SD's ESP line
echo "UUID=$ESP_UUID  /boot/efi  vfat  umask=0077,nofail  0 1" >> "$FSTAB"

say "[7/8] Rebuild initrd WITH nvme + Tegra-PCIe drivers, install on NVMe"
MODFILE=/etc/initramfs-tools/modules
for m in nvme nvme_core pcie_tegra194 phy_tegra194_p2u; do
  grep -qx "$m" "$MODFILE" 2>/dev/null || echo "$m" >> "$MODFILE"
done
update-initramfs -u -k "$KREL"
SRC_INITRD="/boot/initrd.img-$KREL"
# verify source (capture to var; do NOT pipe under pipefail)
LIST="$(lsinitramfs "$SRC_INITRD" 2>/dev/null || true)"
echo "$LIST" | grep -qi 'nvme\.ko'        || die "rebuilt initrd is missing nvme.ko"
echo "$LIST" | grep -qi 'pcie-tegra194'   || die "rebuilt initrd is missing pcie-tegra194"
[ -f "$MNT/boot/initrd" ] && cp -a "$MNT/boot/initrd" "$MNT/boot/initrd.orig" || true
cp "$SRC_INITRD" "$MNT/boot/initrd"
sync
LIST2="$(lsinitramfs "$MNT/boot/initrd" 2>/dev/null || true)"
echo "$LIST2" | grep -qi 'nvme\.ko' && echo "    OK: NVMe /boot/initrd contains the drivers." \
                                    || die "NVMe /boot/initrd verification failed."

say "[8/8] Verify & unmount"
parted "$NVME_DISK" print
blkid "$APP_PART" "$ESP_PART"
umount "$MNT"

cat <<EOF

===============================================================================
 DONE.  System cloned to $NVME_DISK.

   1) sudo poweroff
   2) remove the microSD card
   3) power on   ->   boots from NVMe

 Verify after boot:   findmnt /     (should show $APP_PART)
                      df -h /       (should show the full SSD)

 Rollback: put the SD card back in and boot — it is unchanged.
 Log:      $LOG
===============================================================================
EOF
