#!/bin/bash
# ============================================================================
# m1.sh — Unified M1 kernel tool for Apple M1 (T8103) on Fedora Asahi Remix
#
# Subcommands:
#   build              Copy config-m1-final, olddefconfig, validate, build RPM
#   install            Install RPM + postinstall (relabel, dracut, grubby) + services
#   all                build + install (default if no arg)
#   postinstall        Run only post-install steps (after manual `dnf install`)
#   validate [cfg]     Run config validator (default: .config)
#   release            Create GitHub Release with latest built RPM
#   download [tag]     Download RPM from GitHub Release (latest if no tag) and install
#   help               Show this help
#
# Examples:
#   ./m1.sh                          # build + install
#   ./m1.sh build                    # build only, no install
#   ./m1.sh validate config-m1-final # check config without building
#   sudo ./m1.sh postinstall         # after manual `dnf install kernel-*.rpm`
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[m1]${NC} $*"; }
warn() { echo -e "${YELLOW}[m1]${NC} $*"; }
err()  { echo -e "${RED}[m1]${NC} $*" >&2; }

# ============================================================================
# Validate — check Apple drivers in given config
# ============================================================================
cmd_validate() {
    local cfg="${1:-.config}"
    [ -f "$cfg" ] || { err "$cfg not found"; return 1; }

    local errors=0
    check_ym() {
        local key="$1" desc="$2"
        local val
        val="$(grep "^${key}=" "$cfg" | cut -d= -f2)"
        if [ -z "$val" ] || [[ "$val" != "y" && "$val" != "m" ]]; then
            echo "  MISSING: $key ($desc)"
            errors=$((errors + 1))
        fi
    }
    check_y() {
        local key="$1" desc="$2"
        local val
        val="$(grep "^${key}=" "$cfg" | cut -d= -f2)"
        [ "$val" = "y" ] || { echo "  MISSING: $key=y ($desc)"; errors=$((errors + 1)); }
    }

    echo "Validating: $cfg"
    echo "============================================"

    echo "[Platform]"
    check_ym CONFIG_ARCH_APPLE     "Apple SoC platform"
    check_ym CONFIG_PCIE_APPLE     "Apple PCIe controller"
    check_y  CONFIG_ARM64          "ARM64 architecture"

    echo "[Storage]"
    check_ym CONFIG_BLK_DEV_NVME   "NVMe block device"
    check_ym CONFIG_NVME_APPLE     "Apple NVMe controller"
    check_ym CONFIG_NVME_CORE      "NVMe core"

    echo "[Display]"
    check_ym CONFIG_DRM_APPLE      "Apple DRM/GPU"
    check_ym CONFIG_APPLE_DART     "Apple IOMMU (DART)"

    echo "[Audio]"
    check_ym CONFIG_SND_SOC_APPLE_MCA      "Apple MCA audio"
    check_ym CONFIG_SND_SOC_APPLE_MACAUDIO "Apple MacAudio machine driver"

    echo "[WiFi/BT]"
    check_ym CONFIG_BRCMFMAC       "Broadcom WiFi (brcmfmac)"
    check_ym CONFIG_BRCMFMAC_PCIE  "brcmfmac PCIe transport"
    check_ym CONFIG_BRCMFMAC_WCC   "brcmfmac WCC vendor (BCM4378)"
    check_ym CONFIG_BT             "Bluetooth core"
    check_ym CONFIG_BT_HCIBCM4377  "Apple BCM4377 Bluetooth"

    echo "[Input]"
    check_ym CONFIG_SPI_HID_APPLE_CORE "Apple SPI HID (keyboard/trackpad)"
    check_ym CONFIG_SPI_HID_APPLE_OF   "Apple SPI HID OF"
    check_ym CONFIG_HID_APPLE          "Apple HID"
    check_ym CONFIG_INPUT_MACSMC_INPUT "MacSMC input (power button)"

    echo "[USB]"
    check_ym CONFIG_USB_XHCI_HCD   "xHCI USB host"
    check_ym CONFIG_USB_DWC3_APPLE "Apple DWC3 USB"
    check_ym CONFIG_PHY_APPLE_ATC  "Apple Type-C PHY"

    echo "[Power/SMC]"
    check_ym CONFIG_MFD_MACSMC         "Apple SMC (MFD)"
    check_ym CONFIG_GPIO_MACSMC        "Apple SMC GPIO"
    check_ym CONFIG_CHARGER_MACSMC     "Apple SMC charger"
    check_ym CONFIG_RTC_DRV_MACSMC     "Apple SMC RTC"
    check_ym CONFIG_APPLE_WATCHDOG     "Apple watchdog"
    check_ym CONFIG_POWER_RESET_MACSMC "Apple SMC reboot/poweroff"

    echo "[Bus/Infra]"
    check_ym CONFIG_SPI_APPLE          "Apple SPI"
    check_ym CONFIG_I2C_APPLE          "Apple I2C"
    check_ym CONFIG_SPMI_APPLE         "Apple SPMI"
    check_ym CONFIG_PINCTRL_APPLE_GPIO "Apple GPIO pinctrl"
    check_ym CONFIG_APPLE_MAILBOX      "Apple mailbox"
    check_ym CONFIG_APPLE_RTKIT        "Apple RTKit"
    check_ym CONFIG_APPLE_SART         "Apple SART"
    check_ym CONFIG_APPLE_ADMAC        "Apple ADMAC (audio DMA)"
    check_ym CONFIG_APPLE_SIO          "Apple SIO"
    check_ym CONFIG_APPLE_DOCKCHANNEL  "Apple Dock Channel"
    check_ym CONFIG_IOMMU_IO_PGTABLE_DART "DART page table"

    echo "[CPU/Perf]"
    check_ym CONFIG_ARM_APPLE_CPUIDLE     "Apple CPU idle"
    check_ym CONFIG_ARM_APPLE_SOC_CPUFREQ "Apple cpufreq"
    check_ym CONFIG_APPLE_M1_CPU_PMU      "Apple M1 PMU"
    check_y  CONFIG_APPLE_AIC             "Apple AIC interrupt controller"

    echo "[NVMEM/Clocks]"
    check_ym CONFIG_NVMEM_APPLE_EFUSES "Apple eFuses"
    check_ym CONFIG_NVMEM_APPLE_SPMI   "Apple SPMI NVMEM"
    check_ym CONFIG_COMMON_CLK_APPLE_NCO "Apple NCO clock"

    echo "[Display PHY]"
    check_ym CONFIG_PHY_APPLE_DPTX "Apple DisplayPort TX PHY"

    echo "[Camera]"
    check_ym CONFIG_VIDEO_APPLE_ISP "Apple ISP (webcam)"

    echo "============================================"
    if [ "$errors" -eq 0 ]; then
        log "All Apple drivers OK"
        return 0
    else
        err "$errors issues found"
        return 1
    fi
}

# ============================================================================
# Build — copy config, olddefconfig, validate, build RPM
# ============================================================================
cmd_build() {
    [ -f config-m1-final ] || { err "config-m1-final missing"; return 1; }
    [ -f Makefile ]        || { err "No Makefile — not a kernel source tree"; return 1; }

    log "Copying config-m1-final → .config"
    cp config-m1-final .config
    rm -f include/config/auto.conf include/config/auto.conf.cmd

    log "Resolving new symbols (non-interactive)"
    make olddefconfig < /dev/null >/dev/null || true
    yes "" | make oldconfig >/dev/null 2>&1 || true

    cmd_validate .config || { err "Validation failed — aborting"; return 1; }

    log "Building binrpm-pkg (~15-25 min)"
    PATH="$HOME/.cargo/bin:$PATH" make -j"$(nproc)" binrpm-pkg < /dev/null

    if ! diff -q .config config-m1-final >/dev/null 2>&1; then
        log "Syncing resolved .config → config-m1-final"
        cp .config config-m1-final
    fi
}

# ============================================================================
# Postinstall — relabel, dracut, grubby (run after RPM install)
# ============================================================================
cmd_postinstall() {
    local kver="${1:-}"
    if [ -z "$kver" ]; then
        # Latest installed in /lib/modules
        kver="$(ls -1t /lib/modules/ 2>/dev/null | head -1)"
    fi
    [ -d "/lib/modules/$kver" ] || { err "/lib/modules/$kver missing"; return 1; }

    log "Post-install for kernel $kver"

    log "Relabeling SELinux on /lib/modules/$kver"
    sudo restorecon -RF "/lib/modules/$kver/" 2>&1 | tail -3

    log "Regenerating initramfs"
    sudo dracut -f --kver "$kver" 2>&1 | tail -3
    log "initramfs: $(ls -lh /boot/initramfs-$kver.img 2>/dev/null | awk '{print $5}')"

    if command -v grubby >/dev/null 2>&1; then
        sudo grubby --set-default="/boot/vmlinuz-$kver" >/dev/null 2>&1 \
            && log "Default boot entry → $kver"
    fi

    log "Restoring SELinux labels on /lib/firmware (preserves WiFi symlinks)"
    sudo restorecon -RF /lib/firmware/brcm/ 2>/dev/null

    sync
    log "Post-install done"
}

# ============================================================================
# Install — install RPM + postinstall + system services
# ============================================================================
cmd_install() {
    local rpm
    rpm="$(ls -t rpmbuild/RPMS/aarch64/kernel-*.rpm 2>/dev/null | grep -v -- '-devel-' | head -1)"
    [ -n "$rpm" ] || { err "No kernel RPM in rpmbuild/RPMS/aarch64/ — run build first"; return 1; }
    log "Installing $rpm"

    if ! sudo rpm -Uvh --replacefiles --replacepkgs "$rpm"; then
        warn "rpm -U failed — falling back to dnf"
        sudo dnf install -y --allowerasing "$rpm"
    fi

    local rel
    rel="$(make -s kernelrelease 2>/dev/null || ls -1t /lib/modules/ | head -1)"
    cmd_postinstall "$rel"

    if [ ! -f /etc/modules-load.d/bluetooth.conf ]; then
        log "Enabling hci_bcm4377 autoload"
        echo "hci_bcm4377" | sudo tee /etc/modules-load.d/bluetooth.conf >/dev/null
    fi

    if [ ! -f /usr/local/sbin/m1-wifi-firmware-fix.sh ]; then
        log "Installing WiFi firmware symlink service"
        sudo cp m1-wifi-firmware-fix.sh      /usr/local/sbin/
        sudo cp m1-wifi-firmware-fix.service /etc/systemd/system/
        sudo systemctl enable --now m1-wifi-firmware-fix.service
    fi

    if ! systemctl is-enabled m1-battery-optimize.service &>/dev/null; then
        log "Installing battery runtime service"
        sudo cp m1-battery-optimize.sh      /usr/local/bin/
        sudo chmod +x /usr/local/bin/m1-battery-optimize.sh
        sudo cp m1-battery-optimize.service /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable m1-battery-optimize.service
    fi

    echo ""
    log "=== Installed kernel $rel ==="
    log "Next: sudo reboot"
    log "Verify after reboot:"
    log "  uname -r                                            # $rel"
    log "  cat /sys/devices/system/cpu/cpuidle/current_driver  # apple_idle"
    log "  systemctl status m1-battery-optimize                # active"
}

# ============================================================================
# Release — create GitHub Release with built RPM
# Repo: wilfredor/m1-kernel (override with M1_REPO env var)
# Tag derived from RPM filename: kernel-6.18.15_m1opt+-18.aarch64.rpm → v6.18.15-18
# ============================================================================
cmd_release() {
    local repo="${M1_REPO:-wilfredor/m1-kernel}"
    command -v gh >/dev/null || { err "gh CLI not installed"; return 1; }

    local rpm
    rpm="$(ls -t rpmbuild/RPMS/aarch64/kernel-*.rpm 2>/dev/null | grep -v -- '-devel-\|-headers-' | head -1)"
    [ -n "$rpm" ] || { err "No kernel RPM in rpmbuild/RPMS/aarch64/ — run build first"; return 1; }

    # Derive tag and version from RPM name
    local rpmbase ver build tag
    rpmbase="$(basename "$rpm" .aarch64.rpm)"
    ver="${rpmbase#kernel-}"        # 6.18.15_m1opt+-18
    build="${ver##*-}"              # 18
    ver="${ver%-*}"                 # 6.18.15_m1opt+
    ver="${ver/_m1opt+/}"           # 6.18.15
    tag="v${ver}-${build}"

    log "Repo: $repo"
    log "RPM:  $rpm ($(ls -lh "$rpm" | awk '{print $5}'))"
    log "Tag:  $tag"

    # Optional kernel-devel + headers as additional assets
    local extras=()
    for kind in devel headers; do
        local f
        f="$(ls -t rpmbuild/RPMS/aarch64/kernel-${kind}-*.rpm 2>/dev/null | head -1)"
        [ -n "$f" ] && extras+=("$f")
    done

    local notes
    notes="$(mktemp)"
    cat > "$notes" <<EOF
M1-optimized kernel for Apple M1 (T8103) on Fedora Asahi Remix.

**Kernel:** ${ver}, build ${build}
**Base:** Asahi Linux upstream

## Install

\`\`\`bash
gh release download ${tag} -R ${repo} -p '*.rpm'
sudo ./m1.sh install
\`\`\`

Or via m1.sh directly:

\`\`\`bash
./m1.sh download ${tag}
\`\`\`

See [README](https://github.com/${repo}/blob/main/README.md) for full setup.
EOF

    if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
        warn "Release $tag exists — uploading assets with --clobber"
        gh release upload "$tag" "$rpm" "${extras[@]}" -R "$repo" --clobber
    else
        log "Creating release $tag"
        gh release create "$tag" "$rpm" "${extras[@]}" \
            -R "$repo" \
            --title "Kernel ${ver}-${build}" \
            --notes-file "$notes"
    fi

    rm -f "$notes"
    log "Release $tag → https://github.com/${repo}/releases/tag/${tag}"
}

# ============================================================================
# Download — fetch RPM from GitHub Release and install
# ============================================================================
cmd_download() {
    local repo="${M1_REPO:-wilfredor/m1-kernel}"
    local tag="${1:-}"
    command -v gh >/dev/null || { err "gh CLI not installed"; return 1; }

    local destdir
    destdir="$(mktemp -d)"
    cd "$destdir"

    if [ -z "$tag" ]; then
        log "Fetching latest release from $repo"
        gh release download -R "$repo" -p '*.rpm' || { err "download failed"; return 1; }
    else
        log "Fetching $tag from $repo"
        gh release download "$tag" -R "$repo" -p '*.rpm' || { err "download failed"; return 1; }
    fi

    local rpm
    rpm="$(ls kernel-*.rpm 2>/dev/null | grep -v -- '-devel-\|-headers-' | head -1)"
    [ -n "$rpm" ] || { err "No kernel RPM downloaded"; return 1; }
    log "Downloaded: $rpm ($(ls -lh "$rpm" | awk '{print $5}'))"

    log "Installing"
    sudo rpm -Uvh --replacefiles --replacepkgs "$rpm" || \
        sudo dnf install -y --allowerasing "$rpm"

    # KVER from RPM filename
    local kver
    kver="$(rpm -qpl "$rpm" 2>/dev/null | grep -m1 '/lib/modules/' | sed -n 's|^/lib/modules/\([^/]*\)/.*|\1|p')"
    [ -z "$kver" ] && kver="$(ls -1t /lib/modules/ | head -1)"

    cd "$SCRIPT_DIR"
    rm -rf "$destdir"

    cmd_postinstall "$kver"
    log "Done — sudo reboot to use $kver"
}

# ============================================================================
# Help
# ============================================================================
cmd_help() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
}

# ============================================================================
# Dispatch
# ============================================================================
case "${1:-all}" in
    build)        cmd_build ;;
    install)      cmd_install ;;
    all|"")       cmd_build && cmd_install ;;
    postinstall)  shift; cmd_postinstall "${1:-}" ;;
    validate)     shift; cmd_validate "${1:-.config}" ;;
    release)      cmd_release ;;
    download)     shift; cmd_download "${1:-}" ;;
    help|-h|--help) cmd_help ;;
    *) err "Unknown subcommand: $1"; cmd_help; exit 1 ;;
esac
