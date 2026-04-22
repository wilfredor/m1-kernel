#!/bin/bash
# Run from dracut emergency shell or rescue.
# Mounts /boot, dumps full diagnostics to /boot/diag.log.
# After done: shutdown, boot to macOS, read log via debugfs.

BOOT_UUID=107698e4-392a-4bf6-9737-a1e9a84792c1
ROOT_UUID=3cbd9d9a-90a4-404d-afaa-446e1c0722dc

# Try load storage modules in case missing
for m in apple_mailbox apple_rtkit apple_sart apple_nvme nvme_core nvme btrfs crc32c_generic xxhash_generic zstd; do
    modprobe "$m" 2>/dev/null
done
sleep 2

# Find and mount /boot
BOOT_DEV=$(blkid -U "$BOOT_UUID" 2>/dev/null)
[ -z "$BOOT_DEV" ] && BOOT_DEV=/dev/nvme0n1p5
mkdir -p /boot
mountpoint -q /boot || mount -t ext4 "$BOOT_DEV" /boot 2>/dev/null

LOG=/boot/diag.log
exec > "$LOG" 2>&1
set -x

echo "=== uname ==="; uname -a
echo "=== /proc/cmdline ==="; cat /proc/cmdline
echo "=== date ==="; date
echo "=== hostnamectl ==="; hostnamectl 2>&1 || true

echo "=== /proc/version ==="; cat /proc/version
echo "=== /proc/modules count ==="; wc -l /proc/modules

echo "=== block devices ==="
ls -la /dev/nvme* 2>&1
ls -la /dev/disk/by-uuid/ 2>&1
ls -la /dev/disk/by-label/ 2>&1
ls -la /dev/disk/by-partlabel/ 2>&1

echo "=== blkid ==="; blkid 2>&1
echo "=== lsblk ==="; lsblk -f 2>&1
echo "=== /proc/partitions ==="; cat /proc/partitions

echo "=== lsmod ==="; lsmod

echo "=== /lib/modules ==="
ls /lib/modules/ 2>&1
KVER=$(uname -r)
echo "=== modules dir for $KVER ==="
ls /lib/modules/"$KVER"/ 2>&1 | head -30

echo "=== specific modules ==="
for m in apple_nvme nvme btrfs apple_dart apple_admac apple_rtkit apple_sart apple_mailbox brcmfmac brcmfmac_wcc; do
    echo "--- $m ---"
    modinfo "$m" 2>&1 | head -5
    echo "loaded: $(lsmod | grep -c "^${m//-/_}\b")"
done

echo "=== dmesg full ==="; dmesg 2>&1
echo "=== dmesg errors ==="; dmesg 2>&1 | grep -iE "error|fail|warn|panic|oops|cannot|unable|denied"

echo "=== systemctl status ==="; systemctl status 2>&1 | head -50
echo "=== systemctl --failed ==="; systemctl --failed 2>&1
echo "=== systemd-analyze critical-chain ==="; systemd-analyze critical-chain 2>&1 || true
echo "=== systemd-analyze blame ==="; systemd-analyze blame 2>&1 | head -30 || true
echo "=== journalctl -xb (last 400) ==="; journalctl -xb 2>&1 | tail -400
echo "=== journalctl errors ==="; journalctl -xb -p err 2>&1 | tail -100

echo "=== try mount root manually ==="
mkdir -p /mnt/root
mount -t btrfs -o subvol=root,ro UUID="$ROOT_UUID" /mnt/root 2>&1
ls /mnt/root 2>&1 | head
echo "--- /mnt/root/boot ---"
ls /mnt/root/boot 2>&1 | head
echo "--- /mnt/root/lib/modules ---"
ls /mnt/root/lib/modules 2>&1 | head
echo "--- /mnt/root/etc/fstab ---"
cat /mnt/root/etc/fstab 2>&1
umount /mnt/root 2>/dev/null

echo "=== /boot listing ==="; ls -la /boot 2>&1
echo "=== loader entries ==="
ls -la /boot/loader/entries/ 2>&1
for f in /boot/loader/entries/*.conf; do
    echo "--- $f ---"
    cat "$f"
done

echo "=== firmware loaded ==="
ls /lib/firmware/brcm/ 2>&1 | head -40

echo "=== END ==="
date
sync
sync

set +x
echo ""
echo "DONE. Log written to /boot/diag.log"
echo "Now run: poweroff   (then boot to macOS)"
