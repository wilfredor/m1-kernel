#!/bin/bash
# Run from init=/bin/bash:
#   /bin/bash /boot/recovery-info.sh
# Mounts /boot, lists kernel RPMs and dnf cache, dumps to /boot/recovery.log

mount -o remount,rw / 2>/dev/null
mount /boot 2>/dev/null
mount -a 2>/dev/null

LOG=/boot/recovery.log
exec > "$LOG" 2>&1
set -x

echo "=== uname ==="; uname -a
echo "=== date ==="; date

echo "=== mounted filesystems ==="; mount | grep -vE "tmpfs|cgroup|proc|sys|devtmpfs"

echo "=== /home/wilfredor/m1-kernel/rpms/ ==="
ls -la /home/wilfredor/m1-kernel/rpms/ 2>&1

echo "=== ALL kernel RPMs in /home/wilfredor ==="
find /home/wilfredor -name "kernel*.rpm" -type f 2>/dev/null

echo "=== /var/cache/dnf kernel ==="
find /var/cache/dnf -name "kernel*" -type f 2>/dev/null | head -30

echo "=== /var/cache/PackageKit ==="
find /var/cache/PackageKit -name "kernel*" -type f 2>/dev/null | head -10

echo "=== installed kernels (rpm -qa) ==="
rpm -qa kernel 2>&1
rpm -qa | grep -i kernel 2>&1

echo "=== /lib/modules ==="
ls -la /lib/modules/ 2>&1

echo "=== /boot full listing ==="
ls -la /boot/ 2>&1

echo "=== git log m1-kernel HEAD ==="
cd /home/wilfredor/m1-kernel && git log --oneline -20 2>&1

echo "=== git status m1-kernel ==="
cd /home/wilfredor/m1-kernel && git status 2>&1 | head -20

echo "=== END ==="
date
sync; sync

set +x
echo ""
echo "DONE. Log: /boot/recovery.log"
echo "Now: sync; sync; poweroff -f"
