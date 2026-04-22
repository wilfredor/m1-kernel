# M1 Linux Optimized Kernel

Custom Linux kernel for Apple M1 (T8103) on Fedora Asahi Remix.
70% smaller than stock — only Apple hardware, with battery-life patches.

## Results

| Metric | Stock | This kernel |
|--------|-------|-------------|
| Boot time | 13s | **6s** |
| RAM idle | 3.3 GB | **2.6 GB** |
| Modules loaded | 200+ | **61** |
| Disk (kernel+system) | 20 GB | **6.9 GB** |
| Battery | ~5h | **~7-9h** (with all opts) |
| GPU driver | C (appledrm) | **Rust (asahi)** |

## Files

```
m1.sh                          Unified tool — build|install|all|postinstall|validate
m1-battery-optimize.{sh,svc}   Runtime power tuning (installed to /usr/local + systemd)
m1-wifi-firmware-fix.{sh,svc}  brcmfmac firmware symlinks (idempotent, runs each boot)
config-m1-final                Kernel .config (passes validator, all 50 Apple drivers)
rescue/                        Emergency boot recovery scripts + post-mortem logs
```

Driver patches live in the kernel source tree (uncommitted) — see "Driver patches" below.

## Quick start

### Option A: Install pre-built RPM (fast, no build needed)

```bash
git clone https://github.com/wilfredor/m1-kernel.git
cd m1-kernel
./m1.sh download         # fetches latest release RPM, installs, runs postinstall
sudo reboot
```

### Option B: Build from source (15-25 min)

```bash
# Get Asahi kernel source
git clone --depth 1 --branch asahi https://github.com/AsahiLinux/linux.git asahi-src
cd asahi-src

# Bring this project's tooling + patches into the tree
git clone https://github.com/wilfredor/m1-kernel.git ../m1-kernel-tools
cp ../m1-kernel-tools/{m1.sh,config-m1-final,m1-*.sh,m1-*.service} .
cp -r ../m1-kernel-tools/{rescue,patches} .

# Apply driver patches (battery optimizations)
git apply patches/0001-m1-battery-driver-optimizations.patch

# Build deps (Fedora)
sudo dnf install -y gcc make flex bison openssl-devel elfutils-devel \
    rpm-build perl bc dwarves rust rust-src
cargo install bindgen-cli

# Build + install
./m1.sh                # = build + install
sudo reboot
```

## Subcommands

```
./m1.sh                    Build + install (default)
./m1.sh build              Build RPM only
./m1.sh install            Install last-built RPM + post-install
./m1.sh postinstall        Run post-install only (after manual `dnf install kernel-*.rpm`)
./m1.sh validate [cfg]     Validate config (default: .config)
./m1.sh release            Build + create GitHub Release (maintainer-only)
./m1.sh download [tag]     Download release RPM and install (default: latest)
./m1.sh help
```

## Hardware support

**Built-in:** Apple PCIe, NVMe (ANS2), DART, AIC, Mailbox, RTKit, SPI keyboard/trackpad,
SMC (power, battery, charger, RTC, GPIO, watchdog), USB-C (DWC3+PHY), clocks, pinctrl,
SPMI, NVMEM, CPU idle/cpufreq/PMU.

**Modules:** WiFi (brcmfmac BCM4378 + WCC/BCA/CYW), Bluetooth (hci_bcm4377),
GPU (Asahi Rust), Audio (MCA + MacAudio), Display (apple-drm/DCP), ISP (webcam),
USB (storage, CDC ethernet, HID).

**NOT included:** USB serial, USB WiFi dongles, joysticks, Wacom tablets,
non-Broadcom Bluetooth, PCI ethernet/WiFi cards.

## Driver patches (uncommitted in kernel tree)

```
drivers/cpufreq/apple-soc-cpufreq.c        battery-aware P-core cap (80% on DC)
drivers/cpuidle/cpuidle-apple.c            ACC_OVRD deeper cluster gating
drivers/nvme/host/apple.c                  runtime PM autosuspend (ANS idle)
drivers/power/supply/macsmc-power.c        hw_protection_trigger + power_stats sysfs
drivers/soc/apple/mailbox.c                runtime PM autosuspend (50ms)
drivers/spi/spi-apple.c                    runtime PM autosuspend (200ms) + clk gating
drivers/i2c/busses/i2c-pasemi-platform.c   I2C runtime PM (1000ms)
```

Total estimated savings: **0.7-1.5 W**, **+60-130 min** battery vs stock.

Commit before `git pull` or they will be lost.

## ⚠ Critical: post-install relabel

Manual `dnf install kernel-*.rpm` leaves modules with SELinux ctx `unlabeled_t`.
Enforcing then blocks `bluetooth.ko`/`fuse`/`i2c_dev`/`uinput` → systemd-modules-load
fails → cascade → forced shutdown. **Always run after manual install:**

```bash
sudo ./m1.sh postinstall
```

`./m1.sh install` (and `./m1.sh all`) does this automatically.

## Troubleshooting

**Boot fails (modules denied, zram timeout, forced shutdown):**
Add `init=/bin/bash` to kernel cmdline at m1n1/GRUB. At root shell:
```bash
bash /home/wilfredor/m1-kernel/rescue/fix-asahi.sh
echo b > /proc/sysrq-trigger
```

**Modules fail with SELinux AVC denials (`unlabeled_t`):**
```bash
sudo restorecon -Rv /lib/modules/$(uname -r)/
```

**Bluetooth not auto-loading:**
```bash
echo "hci_bcm4377" | sudo tee /etc/modules-load.d/bluetooth.conf
```

**WiFi firmware fails (`brcmfmac4378b1-pcie.sig failed with error -2`):**
Service should already handle this. If missing:
```bash
sudo cp m1-wifi-firmware-fix.sh      /usr/local/sbin/
sudo cp m1-wifi-firmware-fix.service /etc/systemd/system/
sudo systemctl enable --now m1-wifi-firmware-fix.service
```

**WiFi missing after build (vendor module lost):**
Confirm `config-m1-final` has `CONFIG_BRCMFMAC_WCC/BCA/CYW=m`.

## Battery optimization details

**Boot params** (in `/etc/default/grub` or BLS entry):
```
workqueue.power_efficient=1   Consolidate workqueues to fewer CPUs (idle cores stay deep)
fw_devlink=permissive         Skip 130s probe wait for unbound apple,s5l-uart debug ports
```

**Charge threshold (longevity):**
```bash
echo 75 | sudo tee /sys/class/power_supply/macsmc-battery/charge_control_start_threshold
echo 80 | sudo tee /sys/class/power_supply/macsmc-battery/charge_control_end_threshold
```

**Power monitoring:**
```bash
cat /sys/class/power_supply/macsmc-battery/power_now              # microwatts
cat /sys/devices/platform/soc/23e400000.smc/macsmc-power/power_stats  # rail breakdown
```

**Per-optimization estimated savings:**

| Optimization | Savings | Battery |
|--------------|---------|---------|
| HZ=250, ASPM, governors (config) | 0.2-0.4 W | +15-30 min |
| cpuidle ACC_OVRD deep idle | 0.15-0.25 W | +10-20 min |
| Boot params (workqueue, fw_devlink) | 0.05-0.15 W | +5-15 min |
| Runtime tweaks (m1-battery-optimize) | 0.10-0.20 W | +10-15 min |
| NVMe RTKit idle | 0.10-0.20 W | +10-20 min |
| SPI + I2C + Mailbox runtime PM | 0.07-0.18 W | +5-15 min |
| cpufreq battery cap (80%) | 0.05-0.15 W | +5-15 min |

## Updating to new Asahi kernel

```bash
git pull              # commit driver patches first!
./m1.sh               # build + install + postinstall
sudo reboot
```
