#!/bin/bash
# Run from bash on rootfs (init=/bin/bash boot, kernel cmdline has rw)
set +e

echo "=== Asahi fix script ==="

# Mount essentials (skip / remount - kernel already mounted rw)
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null

# Mount /boot, /home, /var by device path (no UUID resolution available)
mountpoint -q /boot || mount -t ext4 /dev/nvme0n1p5 /boot
mountpoint -q /home || mount -t btrfs -o subvol=home /dev/nvme0n1p6 /home
mountpoint -q /var  || mount -t btrfs -o subvol=var  /dev/nvme0n1p6 /var
mountpoint -q /boot/efi || mount -t vfat /dev/nvme0n1p4 /boot/efi 2>/dev/null

echo ""
echo ">>> mounts:"
mount | grep -vE "tmpfs|cgroup"

echo ""
echo ">>> Disabling SELinux in /etc/selinux/config"
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
grep ^SELINUX= /etc/selinux/config

echo ""
echo ">>> Restoring SELinux labels (best effort)"
restorecon -RFv /lib/modules/ 2>&1 | head -10
chcon -R -t modules_object_t /lib/modules/ 2>&1 | head -3

echo ""
echo ">>> Regenerating initramfs"
dracut -f --kver 6.18.15-m1opt+ 2>&1 | tail -10
ls -la /boot/initramfs-6.18.15-m1opt+.img

echo ""
echo ">>> Restoring loader entry"
cat > /boot/loader/entries/a2a47b05f5f24e679b6b3b0780a58ce4-6.18.15-m1opt+.conf <<'LE'
title Fedora Linux Asahi Remix (6.18.15-m1opt+) 43 (Workstation Edition)
version 6.18.15-m1opt+
linux /vmlinuz-6.18.15-m1opt+
initrd /initramfs-6.18.15-m1opt+.img $tuned_initrd
options root=UUID=3cbd9d9a-90a4-404d-afaa-446e1c0722dc ro rootflags=subvol=root selinux=0 rhgb quiet workqueue.power_efficient=1 fw_devlink=permissive $tuned_params
grub_users $grub_users
grub_arg --unrestricted
grub_class fedora-asahi-remix
LE

echo ""
echo ">>> Setting boot default"
cat > /boot/grub2/grubenv <<'GE'
# GRUB Environment Block
boot_success=0
boot_indeterminate=0
saved_entry=a2a47b05f5f24e679b6b3b0780a58ce4-6.18.15-m1opt+
GE
SIZE=$(stat -c%s /boot/grub2/grubenv)
PAD=$((1024 - SIZE))
[ $PAD -gt 0 ] && head -c $PAD /dev/zero | tr '\0' '#' >> /boot/grub2/grubenv

sync; sync; sync
echo ""
echo "=== DONE ==="
echo "Para reiniciar ahora:"
echo "  echo b > /proc/sysrq-trigger"
echo "(o mantén power 5s)"
