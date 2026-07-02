#!/bin/bash
# =============================================================================
# fix-initrd.sh — FIX for: the NVMe boot reaches the kernel but fails with
# "ALERT! /dev/nvme0n1p1 does not exist" / "nvme0n1p1 not found" and drops to
# an (initramfs) shell.
#
# Cause: the L4T /boot/initrd does NOT include the NVMe + Tegra-PCIe drivers,
# so the kernel can't see the NVMe early enough to mount root from it.
#
# This rebuilds the initrd WITH those drivers and installs it on the NVMe.
# Run from the SD system with sudo. Does NOT change how the SD boots.
#
# (clone-sd-to-nvme.sh already does this — you only need this if you cloned
#  some other way.)
# =============================================================================
set -eu

NVME_ROOT="${1:-/dev/nvme0n1p1}"
MNT=/mnt/nvme
KREL="$(uname -r)"
say(){ echo -e "\n\033[1;36m==> $*\033[0m"; }
die(){ echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
[ "$EUID" -eq 0 ] || die "run with sudo"
[ -b "$NVME_ROOT" ] || die "$NVME_ROOT is not a block device"

say "[1/4] force nvme + Tegra-PCIe modules into the initramfs module list"
MODFILE=/etc/initramfs-tools/modules
for m in nvme nvme_core pcie_tegra194 phy_tegra194_p2u; do
  grep -qx "$m" "$MODFILE" 2>/dev/null || { echo "$m" >> "$MODFILE"; echo "   + $m"; }
done

say "[2/4] regenerate the initramfs (SD boot uses a different initrd, unaffected)"
update-initramfs -u -k "$KREL"
SRC="/boot/initrd.img-$KREL"
# NOTE: verify via captured variable — 'lsinitramfs | grep' under 'set -o pipefail'
# can falsely fail because lsinitramfs returns non-zero on warnings.
LIST="$(lsinitramfs "$SRC" 2>/dev/null || true)"
echo "$LIST" | grep -qi 'nvme\.ko'      || die "rebuilt initrd missing nvme.ko"
echo "$LIST" | grep -qi 'pcie-tegra194' || die "rebuilt initrd missing pcie-tegra194.ko"
echo "   OK: $SRC contains nvme + pcie drivers"

say "[3/4] install it as the NVMe's /boot/initrd (backing up the original)"
umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"; mount "$NVME_ROOT" "$MNT"
[ -f "$MNT/boot/initrd" ] && [ ! -f "$MNT/boot/initrd.orig" ] && cp -a "$MNT/boot/initrd" "$MNT/boot/initrd.orig" || true
cp "$SRC" "$MNT/boot/initrd"
sync

say "[4/4] verify the initrd now on the NVMe"
LIST2="$(lsinitramfs "$MNT/boot/initrd" 2>/dev/null || true)"
echo "$LIST2" | grep -qi 'nvme\.ko' && echo "   OK: NVMe /boot/initrd now has nvme drivers." \
                                    || die "verification failed"
grep -E 'INITRD|APPEND .*root=' "$MNT/boot/extlinux/extlinux.conf" | sed 's/^/    /'
umount "$MNT"

echo -e "\nDone.  sudo poweroff -> remove SD -> power on.  Verify: findmnt /"
