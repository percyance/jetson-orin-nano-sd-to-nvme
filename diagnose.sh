#!/bin/bash
# =============================================================================
# diagnose.sh — read-only diagnostics for Jetson Orin Nano SD->NVMe boot issues.
# Changes NOTHING. Run with sudo and paste the output when asking for help.
#   sudo ./diagnose.sh
# =============================================================================
KREL="$(uname -r)"
NVME_DISK="$(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /nvme/ {print $1; exit}')"

echo "===== [1] current root / boot device ====="
findmnt -n -o SOURCE,FSTYPE /
echo "cmdline: $(cat /proc/cmdline)"

echo; echo "===== [2] block devices ====="
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT

echo; echo "===== [3] UEFI boot entries (needs efibootmgr) ====="
efibootmgr -v 2>/dev/null || echo "efibootmgr not installed (sudo apt install efibootmgr)"

echo; echo "===== [4] NVMe partition table ====="
[ -n "$NVME_DISK" ] && parted "$NVME_DISK" print 2>&1 || echo "no NVMe disk found"

echo; echo "===== [5] partition UUIDs / types ====="
blkid | grep -E 'nvme|mmcblk' || true

echo; echo "===== [6] does /boot/initrd contain nvme + pcie drivers? ====="
if command -v lsinitramfs >/dev/null; then
  hits="$(lsinitramfs /boot/initrd 2>/dev/null | grep -iE 'nvme\.ko|nvme-core|pcie-tegra194|tegra194-p2u')"
  if [ -n "$hits" ]; then echo "$hits"; else
    echo ">>> NONE — /boot/initrd has NO nvme/pcie drivers (would cause 'nvme0n1p1 not found')"
  fi
else
  echo "lsinitramfs not available"
fi

echo; echo "===== [7] are the driver modules present in the rootfs? ====="
find "/lib/modules/$KREL" \( -iname 'nvme.ko' -o -iname 'pcie-tegra194.ko' -o -iname 'phy-tegra194-p2u.ko' \) 2>/dev/null \
  || echo "modules not found for $KREL"

echo; echo "===== [8] extlinux.conf ====="
grep -E 'LABEL|LINUX|INITRD|APPEND' /boot/extlinux/extlinux.conf 2>/dev/null | grep -v '^#'

echo; echo "===== done ====="
