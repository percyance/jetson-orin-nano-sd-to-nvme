# Jetson Orin Nano：从 SD 卡迁移系统到 NVMe SSD

**一条命令，在板子上把正在运行的 JetPack 6 系统整体搬到 NVMe SSD —— 不需要另一台 Ubuntu 主机，不需要 SDK Manager，不需要重新烧录。**

> **English TL;DR** — Clone a *running* NVIDIA Jetson Orin Nano (JetPack 6 / L4T R36)
> from its microSD card to an NVMe SSD, entirely on-device. No host PC, no SDK
> Manager, no re-flash. Run `sudo ./clone-sd-to-nvme.sh` from the SD system, then
> `poweroff`, remove the SD card, and boot from NVMe. The script handles the three
> things a working NVMe boot needs — rootfs clone, an **ESP** on the NVMe, and an
> **initrd rebuilt with the NVMe/PCIe drivers** — the last two of which most guides
> forget, causing "drops to UEFI shell" and "`nvme0n1p1 not found`".

---

## ✨ 为什么需要这个

Orin Nano 官方推荐用 SDK Manager 从 x86 Ubuntu 主机刷 NVMe，但很多人手头没有那台主机，或者被 SDK Manager 各种报错卡住。网上"在板子上 rsync 克隆"的教程又几乎都只做了第一步，结果拔卡后不是掉进 UEFI 命令行，就是报 `nvme0n1p1 not found`。

这个脚本把**三件事一次做对**，所以拔卡即用。

## ✅ 适用环境

| 项目 | 要求 |
| --- | --- |
| 设备 | Jetson Orin Nano / Orin NX Developer Kit |
| 系统 | **JetPack 6.x / L4T R36**（本仓库在 R36.4.7 上验证）|
| 当前启动 | 正从 **microSD 卡** 启动（`findmnt /` 显示 `mmcblk*`）|
| 目标盘 | 已插好的 **NVMe M.2 SSD**（会被**完全格式化**）|

> ⚠️ 目标 NVMe 会被清空。**SD 卡全程不动**，永远是你的退路。

## 🚀 快速使用

```bash
git clone https://github.com/percyance/jetson-orin-nano-sd-to-nvme.git
cd jetson-orin-nano-sd-to-nvme
chmod +x *.sh troubleshooting/*.sh

sudo ./clone-sd-to-nvme.sh          # 按提示输入 YES

sudo poweroff                       # 关机
# 拔掉 microSD 卡
# 重新上电 → 从 NVMe 启动
```

开机后确认：

```bash
findmnt /        # 期望：/dev/nvme0n1p1
df -h /          # 期望：整块 SSD 的容量
```

## 🧩 三个关键点（为什么别的教程会失败）

一个能从 NVMe 启动的 Orin Nano，缺一不可：

| # | 要做的事 | 不做会怎样 |
| --- | --- | --- |
| 1 | **克隆 rootfs**：给 NVMe 分区、格式化、`rsync` 整个根目录 | 没系统可启动 |
| 2 | **建 ESP 分区**：NVMe 上要有一个 FAT32 的 EFI 系统分区，含 `BOOTAA64.efi` | 拔卡后 UEFI 找不到引导器，**掉进 UEFI 命令行/菜单** |
| 3 | **重建 initrd**：把 `nvme`、`pcie-tegra194`、`phy-tegra194-p2u` 驱动打进 `/boot/initrd` | 内核起来了但认不到盘，报 **`nvme0n1p1 not found`**，掉进 `(initramfs)` |

`clone-sd-to-nvme.sh` 三步全包。

## 📂 仓库内容

```
clone-sd-to-nvme.sh          一键克隆（推荐，三步一次做对）
diagnose.sh                  只读诊断，卡住时先跑它、把输出贴出来求助
troubleshooting/
  ├── add-esp.sh             已经克隆过、但拔卡掉进 UEFI 命令行 → 补 ESP（不用重克隆）
  └── fix-initrd.sh          报 nvme0n1p1 not found → 给 initrd 补驱动
```

## 🔧 已经克隆过、卡在某一步？

不用重来，按现象对症下药（都从 SD 系统里跑）：

- **拔卡后掉进 UEFI Shell / 菜单** → 你缺第 2 步的 ESP：
  ```bash
  sudo ./troubleshooting/add-esp.sh          # 默认 /dev/nvme0n1
  ```
- **报 `nvme0n1p1 not found`，掉进 `(initramfs)`** → 你缺第 3 步的 initrd 驱动：
  ```bash
  sudo ./troubleshooting/fix-initrd.sh
  ```
- **不确定** → 先诊断：
  ```bash
  sudo ./diagnose.sh
  ```

## 🩺 原理详解

Orin Nano（UEFI 启动链）：

```
QSPI 里的 UEFI 固件
   └─(BootOrder 里有一项 "UEFI <你的NVMe>")
        └─ 到 NVMe 的 ESP(FAT32) 里加载 \EFI\BOOT\BOOTAA64.efi   ← 需要「关键点 2」
             └─ BOOTAA64.efi = NVIDIA L4TLauncher，去 ext4 根分区读 extlinux.conf
                  └─ 按 extlinux 的 root=/dev/nvme0n1p1 加载 Image + initrd
                       └─ initrd 早期需 nvme/pcie 驱动才能挂上 NVMe 根分区  ← 需要「关键点 3」
```

- **UEFI 读不了 ext4**，只认 FAT 的 ESP。所以哪怕 rsync 把 `BOOTAA64.efi` 复制进了 ext4，UEFI 也用不了——必须有独立的 FAT32 ESP 分区。
- **SD 卡启动时 initrd 只需 mmc 驱动**；NVMe 驱动是系统起来后才在后台加载的。从 NVMe 启动，就必须让 initrd 在早期就带上 `nvme` + Tegra PCIe 控制器/PHY 驱动。

`clone-sd-to-nvme.sh` 里对应的动作：

1. `parted` 建 `p1=APP(ext4)` + `p2=ESP(fat32, esp/boot 标志)`
2. `rsync -aAXH /  →  NVMe:/`（排除 `/dev /proc /sys /tmp /run` 等）
3. 把 `/boot/efi/EFI`（含 `BOOTAA64.efi`）拷进 NVMe 的 ESP
4. `sed` 把 extlinux 的 `root=` 改成 NVMe 分区
5. 改 NVMe 的 `/etc/fstab`：把 `/boot/efi` 指向 NVMe 自己的 ESP（`nofail`，找不到也不卡启动）
6. 把 `nvme nvme_core pcie_tegra194 phy_tegra194_p2u` 加进 `/etc/initramfs-tools/modules`，`update-initramfs -u` 重建，再复制成 NVMe 的 `/boot/initrd`

## ↩️ 回滚

- **SD 卡没被动过**：插回去就能照常启动。
- NVMe 上原始文件都留了备份：`/boot/initrd.orig`、`extlinux.conf.sd.bak`、`fstab.sd.bak`。

## ⚠️ 注意

- 脚本会往**当前 SD 系统**的 `/etc/initramfs-tools/modules` 追加几行（幂等、无害，只是让 SD 以后生成的 initrd 也带 NVMe 驱动），并不改变 SD 的启动方式。
- 目标盘会被**完全清空**，动手前确认里面没有要保留的数据。
- 设备名假定为 `/dev/nvme0n1`；如果你的不一样，把它作为参数传给 troubleshooting 脚本，或改一下主脚本顶部的检测。

## 📜 License

MIT — 详见 [LICENSE](LICENSE)。自担风险使用；刷机有风险，动手前请理解每一步在做什么。

## 🙏 致谢

整理自一次真实的 Orin Nano(JetPack 6 / L4T R36.4.7 + 三星 990 PRO 1TB)迁移过程，把踩过的坑（掉 UEFI 命令行、`nvme0n1p1 not found`）固化成脚本，希望能帮你少走弯路。欢迎提 Issue / PR。
