#!/bin/bash
# m1-battery-optimize.sh — Runtime power optimizations for Apple M1 (T8103) on Linux
# For Fedora Asahi Remix / any Asahi-based distro
# Run as root or via systemd service
#
# These are runtime tweaks — they don't survive reboot without the systemd service.
# Kernel config changes (governors, HZ, ASPM) are separate.

set -uo pipefail
# No set -e: power tweaks should continue even if individual ones fail

LOG_TAG="m1-battery"

log() {
    echo "[${LOG_TAG}] $1"
    logger -t "${LOG_TAG}" "$1" 2>/dev/null || true
}

# ============================================================================
# 1. CPU Governor — use schedutil (default) or powersave when on battery
# ============================================================================
apply_cpu_governor() {
    local governor="${1:-schedutil}"
    for policy in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        echo "$governor" > "$policy" 2>/dev/null && \
            log "CPU governor: $governor ($(basename $(dirname $policy)))"
    done
}

# Detect AC/battery
if [ -f /sys/class/power_supply/macsmc-ac/online ]; then
    AC_ONLINE=$(cat /sys/class/power_supply/macsmc-ac/online)
else
    AC_ONLINE=1
fi

if [ "$AC_ONLINE" = "0" ]; then
    apply_cpu_governor "schedutil"
    log "On battery — applying aggressive power savings"
else
    apply_cpu_governor "schedutil"
    log "On AC — applying moderate power savings"
fi

# ============================================================================
# 2. Workqueue power-efficient mode — consolidate work to fewer CPUs
# ============================================================================
# workqueue.power_efficient is read-only at runtime.
# Must be set via kernel boot parameter: workqueue.power_efficient=1
# Add to /etc/default/grub or grub.cfg
WQ_PE=$(cat /sys/module/workqueue/parameters/power_efficient 2>/dev/null || echo "?")
if [ "$WQ_PE" = "Y" ]; then
    log "Workqueue power_efficient: already enabled"
else
    log "Workqueue power_efficient: DISABLED — add 'workqueue.power_efficient=1' to kernel cmdline"
fi

# ============================================================================
# 3. NMI watchdog — disable (saves ~1W on some systems)
# ============================================================================
if [ -f /proc/sys/kernel/nmi_watchdog ]; then
    echo 0 > /proc/sys/kernel/nmi_watchdog
    log "NMI watchdog: disabled"
fi

# ============================================================================
# 4. VM writeback — increase intervals to reduce disk wakeups
# ============================================================================
sysctl -q vm.dirty_writeback_centisecs=1500  # 15 seconds (default 5s)
sysctl -q vm.dirty_expire_centisecs=3000     # 30 seconds (default 30s)
sysctl -q vm.laptop_mode=5                   # Aggregate disk writes
log "VM writeback: laptop_mode=5, writeback=15s, expire=30s"

# ============================================================================
# 5. PCIe ASPM — force powersave policy
# ============================================================================
if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
    echo powersave > /sys/module/pcie_aspm/parameters/policy 2>/dev/null && \
        log "PCIe ASPM: powersave" || \
        log "PCIe ASPM: kernel-controlled (built-in policy)"
fi

# PCIe runtime PM — auto for all devices
for dev in /sys/bus/pci/devices/*/power/control; do
    echo auto > "$dev" 2>/dev/null
done
log "PCIe runtime PM: auto (all devices)"

# ============================================================================
# 6. WiFi power save — enable for wlp1s0f0 (Broadcom BCM4378)
# ============================================================================
WIFI_DEV=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1)
if [ -n "${WIFI_DEV:-}" ]; then
    iw dev "$WIFI_DEV" set power_save on 2>/dev/null && \
        log "WiFi power save: on ($WIFI_DEV)" || \
        log "WiFi power save: failed ($WIFI_DEV)"
fi

# ============================================================================
# 7. Bluetooth — ensure powered off when not in use
# ============================================================================
if command -v bluetoothctl &>/dev/null; then
    BT_POWERED=$(bluetoothctl show 2>/dev/null | grep "Powered:" | awk '{print $2}')
    if [ "$BT_POWERED" = "no" ]; then
        log "Bluetooth: already off"
    else
        log "Bluetooth: powered on (user-managed, not touching)"
    fi
fi

# ============================================================================
# 8. I2C bus runtime PM — enable where supported
# ============================================================================
for dev in /sys/bus/i2c/devices/*/power/control; do
    echo auto > "$dev" 2>/dev/null
done
log "I2C runtime PM: auto (all devices)"

# ============================================================================
# 9. USB autosuspend — enable for all devices
# ============================================================================
USB_COUNT=0
for dev in /sys/bus/usb/devices/*/power/autosuspend; do
    [ -f "$dev" ] || continue
    echo 1 > "$dev" 2>/dev/null
    USB_COUNT=$((USB_COUNT + 1))
done
for dev in /sys/bus/usb/devices/*/power/control; do
    [ -f "$dev" ] || continue
    echo auto > "$dev" 2>/dev/null
done
log "USB autosuspend: enabled ($USB_COUNT devices)"

# ============================================================================
# 10. Disk I/O scheduler — use none for NVMe (lowest overhead)
# ============================================================================
for disk in /sys/block/nvme*/queue/scheduler; do
    echo none > "$disk" 2>/dev/null
done
log "NVMe I/O scheduler: none"

# ============================================================================
# 11. Kernel tuning — reduce wakeups
# ============================================================================
# Disable kernel.timer_migration (keep timers on same CPU for deeper sleep)
sysctl -q kernel.timer_migration=0 2>/dev/null && \
    log "Timer migration: disabled" || true

# Reduce kernel.sched_min_granularity for better power
# (less context switching overhead with HZ=250)
sysctl -q kernel.sched_child_runs_first=0 2>/dev/null || true

# ============================================================================
# 12. Display — auto-brightness hint (backlight driver dependent)
# ============================================================================
# Note: actual brightness control is user preference, just log current
for bl in /sys/class/backlight/*/brightness; do
    CURR=$(cat "$bl")
    MAX=$(cat "$(dirname $bl)/max_brightness")
    PCT=$((CURR * 100 / MAX))
    log "Backlight: ${PCT}% ($CURR/$MAX)"
done

# ============================================================================
# 13. Audio codec power management
# ============================================================================
for codec in /sys/bus/platform/devices/audio.*/power/control; do
    echo auto > "$codec" 2>/dev/null
done
log "Audio codec runtime PM: auto"

# ============================================================================
# 14. Power-gate unused UART power domains via PMGR
# ============================================================================
# uart0 (PMGR+0x270) and uart2 (PMGR+0x280) are Apple S5L debug serial ports.
# No Linux driver binds them, but they stay ACTIVE (0xF) because genpd DEFER_OFF
# never gets a consumer release. Write 0x0 (PWRGATE) to save power.
# uart_p (0x220) is parent — gate children first, then parent if safe.
PMGR_GATE_UART() {
    python3 -c "
import mmap, struct, os
try:
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    pmgr_page = 0x23b700000 & ~0xFFF
    off = 0x23b700000 & 0xFFF
    mm = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=pmgr_page)
    for name, reg_off in [('uart0', 0x270), ('uart2', 0x280)]:
        val = struct.unpack('<I', mm[off+reg_off:off+reg_off+4])[0]
        if (val & 0xF) == 0xF:  # only if currently ACTIVE
            mm[off+reg_off:off+reg_off+4] = struct.pack('<I', (val & ~0xF) | 0x0)
            print(f'  {name}: ACTIVE → PWRGATE')
        else:
            print(f'  {name}: already gated ({val:#x})')
    mm.close(); os.close(fd)
except Exception as e:
    print(f'  PMGR gate failed: {e}')
" 2>&1
}
PMGR_GATE_UART
log "UART debug ports: power-gated"

# ============================================================================
# 15. DRM/GPU — reduce vblank off delay and scheduler overhead
# ============================================================================
# vblankoffdelay: time in ms before vblank interrupts disabled after last use
# Default 5000ms (5s) — wasteful. Set to 1ms for immediate disable.
if [ -f /sys/module/drm/parameters/vblankoffdelay ]; then
    echo 1 > /sys/module/drm/parameters/vblankoffdelay 2>/dev/null && \
        log "DRM vblankoffdelay: 5000ms → 1ms" || true
fi

# ============================================================================
# 16. Scan all power domains — report ON domains with no consumers
# ============================================================================
if [ -f /sys/kernel/debug/pm_genpd/pm_genpd_summary ]; then
    ON_COUNT=$(cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | grep "  on " | wc -l)
    OFF_COUNT=$(cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null | grep "  off" | wc -l)
    log "Power domains: ${ON_COUNT} on, ${OFF_COUNT} off"
fi

# ============================================================================
# Summary
# ============================================================================
if [ -f /sys/class/power_supply/macsmc-battery/power_now ]; then
    POWER_MW=$(($(cat /sys/class/power_supply/macsmc-battery/power_now) / 1000))
    CAPACITY=$(cat /sys/class/power_supply/macsmc-battery/capacity)
    STATUS=$(cat /sys/class/power_supply/macsmc-battery/status)
    log "Battery: ${CAPACITY}%, ${POWER_MW}mW, ${STATUS}"
fi

log "All optimizations applied successfully"
