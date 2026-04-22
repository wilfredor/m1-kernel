# M1 Linux Optimized Kernel

Optimized Linux kernel for **Apple M1 (T8103)** on Fedora Asahi Remix.
Smaller, faster, longer battery life.

## What you gain

| Metric | Stock Asahi | This kernel | Gain |
|--------|-------------|-------------|------|
| **Battery life** | ~5h | **~7-9h** | **+40-80%** |
| **Boot time** | 13s | **6s** | -54% |
| **RAM idle** | 3.3 GB | **2.6 GB** | -21% |
| **Modules loaded** | 200+ | **61** | -70% |
| **Disk footprint** | 20 GB | **6.9 GB** | -65% |
| **GPU driver** | C (appledrm) | **Rust (asahi)** | new |

Battery gains come from kernel config (HZ=250, ASPM, governors), boot params
(workqueue consolidation), runtime tweaks (NVMe/SPI/I2C/mailbox PM), and
**driver patches** (cpuidle deeper gating, ANS coprocessor idle, P-core cap on DC).

## Install (5 minutes — pre-built RPM)

```bash
git clone https://github.com/wilfredor/m1-kernel.git
cd m1-kernel
./m1.sh download         # downloads latest RPM, installs, runs postinstall
sudo reboot
```

That's it. `./m1.sh download` does the install **AND** runs the critical
post-install steps (SELinux relabel, dracut, grubby) automatically.

## ⚠ If you install the RPM manually, you MUST run postinstall

If you skip `./m1.sh download` and do `dnf install kernel-*.rpm` by hand,
**the system will fail to boot** (SELinux blocks `bluetooth.ko`, `fuse`,
`i2c_dev`, `uinput` → systemd cascade fail → forced shutdown).

Always run after a manual RPM install:

```bash
sudo ./m1.sh postinstall
sudo reboot
```

This is the single most common cause of broken boots after a kernel update.
The postinstall step does:

1. `restorecon` on `/lib/modules/$kver/` (fixes SELinux `unlabeled_t`)
2. `dracut -f` regenerates the initramfs
3. `grubby --set-default` points the bootloader at the new kernel
4. `restorecon` on `/lib/firmware/brcm/` (preserves WiFi symlinks)

## Build from source (15-25 minutes)

Only if you want to customize. Otherwise use the pre-built RPM above.

```bash
git clone --depth 1 --branch asahi https://github.com/AsahiLinux/linux.git asahi-src
cd asahi-src

git clone https://github.com/wilfredor/m1-kernel.git ../m1-tools
cp ../m1-tools/{m1.sh,config-m1-final,m1-*.sh,m1-*.service} .
cp -r ../m1-tools/{rescue,patches} .

git apply patches/0001-m1-battery-driver-optimizations.patch

sudo dnf install -y gcc make flex bison openssl-devel elfutils-devel \
    rpm-build perl bc dwarves rust rust-src
cargo install bindgen-cli

./m1.sh                 # build + install + postinstall
sudo reboot
```

## Commands

```
./m1.sh                  Build + install (default)
./m1.sh download [tag]   Download release RPM and install (default: latest)
./m1.sh install          Install last-built RPM + post-install
./m1.sh postinstall      Post-install only (after manual `dnf install kernel-*.rpm`)
./m1.sh build            Build RPM only
./m1.sh validate [cfg]   Validate config (default: .config)
./m1.sh release          Build + create GitHub Release (maintainer only)
```

## Hardware support

**Built-in:** Apple PCIe, NVMe (ANS2), DART, AIC, Mailbox, RTKit, SPI keyboard/trackpad,
SMC (power, battery, charger, RTC, GPIO, watchdog), USB-C (DWC3+PHY), clocks, pinctrl,
SPMI, NVMEM, CPU idle/cpufreq/PMU.

**Modules:** WiFi (brcmfmac BCM4378 + WCC/BCA/CYW), Bluetooth (hci_bcm4377),
GPU (Asahi Rust), Audio (MCA + MacAudio), Display (apple-drm/DCP), ISP (webcam),
USB (storage, CDC ethernet, HID).

**Not included:** USB serial, USB WiFi dongles, joysticks, Wacom tablets,
non-Broadcom Bluetooth, PCI ethernet/WiFi cards. Add via config + rebuild.

## Driver patches included

| File | Optimization | Savings |
|------|--------------|---------|
| `cpuidle-apple.c` | ACC_OVRD deeper cluster gating, residency 10ms→2ms | 0.15-0.25 W |
| `apple-soc-cpufreq.c` | Battery-aware P-core cap (80% on DC) | 0.05-0.15 W |
| `apple.c` (NVMe) | ANS coprocessor idle via runtime PM (5s autosuspend) | 0.10-0.20 W |
| `spi-apple.c` | Clock gating + runtime PM (200ms) | 0.03-0.08 W |
| `i2c-pasemi-platform.c` | Clock gating + runtime PM (1000ms) | 0.02-0.05 W |
| `mailbox.c` | Autosuspend coalescing (50ms) | 0.02-0.05 W |
| `macsmc-power.c` | hw_protection_trigger + power_stats sysfs | safety/observability |

Combined with config and runtime tweaks: **0.7-1.5 W total**, **+60-130 min** battery.

## Troubleshooting

**Boot fails (modules denied, zram timeout, forced shutdown):**
Boot with `init=/bin/bash` from m1n1/GRUB. At root shell:
```bash
bash /home/wilfredor/m1-kernel/rescue/fix-asahi.sh
echo b > /proc/sysrq-trigger
```

**Modules fail with SELinux AVC `unlabeled_t`:**
```bash
sudo restorecon -Rv /lib/modules/$(uname -r)/
```

**Bluetooth doesn't auto-load:**
```bash
echo "hci_bcm4377" | sudo tee /etc/modules-load.d/bluetooth.conf
```

**WiFi firmware fails (`brcmfmac4378b1-pcie.sig failed -2`):**
The systemd service `m1-wifi-firmware-fix.service` handles this. Verify enabled:
```bash
sudo systemctl status m1-wifi-firmware-fix.service
```

**WiFi missing after build:** Confirm config has `CONFIG_BRCMFMAC_WCC/BCA/CYW=m`.

## Update to new release

```bash
cd m1-kernel
git pull
./m1.sh download         # gets newest RPM, installs, postinstall, ready to reboot
sudo reboot
```

## Optional: battery longevity

Cap charge to 80% to extend battery lifespan:

```bash
echo 75 | sudo tee /sys/class/power_supply/macsmc-battery/charge_control_start_threshold
echo 80 | sudo tee /sys/class/power_supply/macsmc-battery/charge_control_end_threshold
```

## Optional: power monitoring

```bash
cat /sys/class/power_supply/macsmc-battery/power_now              # microwatts
cat /sys/devices/platform/soc/23e400000.smc/macsmc-power/power_stats  # rail breakdown
```

## Boot parameters (recommended)

Add to `/etc/default/grub` `GRUB_CMDLINE_LINUX`:

```
workqueue.power_efficient=1   # consolidate workqueues, idle cores stay deep
fw_devlink=permissive         # skip 130s probe wait for unbound apple,s5l-uart
```

Then `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`.
