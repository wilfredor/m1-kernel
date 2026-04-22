#!/bin/bash
# WiFi firmware crash diag — output to /boot/wifi-diag.txt
exec > /boot/wifi-diag.txt 2>&1
set +e
KV=$(uname -r)
echo "### KERNEL: $KV"
echo "### DATE: $(date)"
echo
echo "===== A. brcmfmac module file paths ====="
modinfo brcmfmac | grep -E 'filename|version|vermagic|srcversion'
echo
echo "===== B. updates/ vs kernel/ brcmfmac ====="
for f in $(find /lib/modules/$KV -name 'brcmfmac.ko*'); do
  echo "-- $f --"
  ls -la "$f"
  modinfo "$f" 2>&1 | grep -E 'version|vermagic|srcversion'
  echo
done
echo
echo "===== C. Asahi kmod packages installed ====="
rpm -qa | grep -iE 'asahi|brcm|kmod|firmware' | sort
echo
echo "===== D. dmesg first 200 lines ====="
dmesg | head -200
echo
echo "===== E. dmesg around brcmfmac (50 before / 50 after) ====="
dmesg | grep -nE 'brcm|wifi|wlan|cfg80211|mac80211|ieee80211|phy0|14e4' | head -60
echo "-- full context lines --"
dmesg > /tmp/_dmesg.txt
LINE=$(grep -n 'brcm' /tmp/_dmesg.txt | head -1 | cut -d: -f1)
if [ -n "$LINE" ]; then
  S=$((LINE-20)); [ $S -lt 1 ] && S=1
  E=$((LINE+80))
  sed -n "${S},${E}p" /tmp/_dmesg.txt
fi
echo
echo "===== F. m1-wifi-firmware-fix.service ====="
systemctl cat m1-wifi-firmware-fix.service 2>&1
echo "-- status --"
systemctl status m1-wifi-firmware-fix.service --no-pager 2>&1 | tail -30
echo "-- journal --"
journalctl -u m1-wifi-firmware-fix.service --no-pager 2>&1 | tail -40
echo
echo "===== G. brcm,board-type from DT ====="
DT=/sys/firmware/devicetree/base/soc/pcie@690000000/pci@0,0/wifi@0,0
echo "-- board-type --"
cat $DT/brcm,board-type 2>&1 | tr '\0' '\n'
echo "-- compatible --"
cat $DT/compatible 2>&1 | tr '\0' '\n'
echo "-- cal-blob size --"
ls -la $DT/brcm,cal-blob 2>&1
echo "-- antenna-sku --"
cat $DT/brcm,antenna-sku 2>&1 | tr '\0' '\n'
echo "-- module-instance --"
cat $DT/module-instance 2>&1 | tr '\0' '\n'
echo "-- all DT files --"
ls $DT/
echo
echo "===== H. brcmfmac4378* firmware files ====="
ls -la /lib/firmware/brcm/brcmfmac4378* 2>&1 | head -40
echo
echo "===== I. brcmfmac variant for this board ====="
BOARD=$(cat $DT/brcm,board-type 2>/dev/null | tr '\0' '\n')
echo "looking for brcmfmac4378*-pcie*$BOARD*"
ls /lib/firmware/brcm/ | grep -E "brcmfmac.*$BOARD" | head -20
echo
echo "===== J. Reload attempt ====="
echo "-- rmmod brcmfmac --"
rmmod brcmfmac 2>&1
echo "-- waiting 2s --"
sleep 2
echo "-- modprobe brcmfmac (with debug) --"
echo 'file fwsig.c +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
echo 'module brcmfmac +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null
modprobe brcmfmac 2>&1
sleep 3
echo "-- after reload, lsmod --"
lsmod | grep brcm
echo "-- after reload, ip link --"
ip -br link
echo "-- after reload, dmesg tail (60 lines) --"
dmesg | tail -60
echo
echo "===== K. PCI rescan attempt ====="
echo "-- unbind/rebind PCI device --"
echo 0000:01:00.0 > /sys/bus/pci/drivers/brcmfmac/unbind 2>&1
sleep 1
echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove 2>&1
sleep 2
echo 1 > /sys/bus/pci/rescan 2>&1
sleep 3
echo "-- after rescan, PCI list --"
for d in /sys/bus/pci/devices/*/; do
  V=$(cat $d/vendor 2>/dev/null); I=$(cat $d/device 2>/dev/null)
  DR=$(basename $(readlink $d/driver 2>/dev/null) 2>/dev/null)
  echo "  $(basename $d) $V:$I driver=${DR:-NONE}"
done
echo "-- after rescan, dmesg tail 40 --"
dmesg | tail -40
echo "-- after rescan, ip link --"
ip -br link
echo
echo "===== L. taint reasons ====="
cat /proc/sys/kernel/tainted
for f in /sys/kernel/tainted; do cat $f; done
echo "-- decode --"
T=$(cat /proc/sys/kernel/tainted)
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  if [ $((T & (1 << i))) -ne 0 ]; then echo "  bit $i set"; fi
done
echo
echo "===== DONE ====="
sync
