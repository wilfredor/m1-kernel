# Rescue scripts and post-mortem logs

Emergency tooling for when M1 kernel install breaks the boot.
**Not used in normal operation** — only when you can't reach a usable login.

## Scripts

| Script | Purpose |
|--------|---------|
| `fix-asahi.sh` | Recovery from `init=/bin/bash` rescue prompt. Disables SELinux, relabels modules, regenerates initramfs, restores loader entry, sets boot default |
| `diag.sh` | Dumps full diagnostics to `diag.log` from dracut emergency shell — load storage modules, mount /boot, capture dmesg/journal/blkid/loader-entries |
| `diag-wifi.sh` | Capture brcmfmac firmware load failures — module info, DT board-type, firmware files, reload trace, PCI rescan attempt |
| `recovery-info.sh` | Quick state dump (kernel version, mounts, loader entries) |

## Replaced by in-tree fixes

| Original problem | Permanent fix in repo |
|------------------|------------------------|
| Boot fails: SELinux blocks `bluetooth.ko`/`fuse`/`uinput` after kernel install | `../m1-kernel-postinstall.sh` (run after every manual kernel RPM install) |
| WiFi firmware not found | `../m1-wifi-firmware-fix.{sh,service}` |
| brcmfmac WCC/BCA/CYW vendor module missing | `CONFIG_BRCMFMAC_WCC/BCA/CYW=m` in `../config-m1-final` |
| BT does not auto-load at boot | `/etc/modules-load.d/bluetooth.conf` (created by `m1-rebuild.sh`) |

## Logs (post-mortem only)

`diag.log`, `fix.log`, `wifi-diag.txt`, `journal-prev.log`, `journal-errors.log`,
`init-progress.log`, `recovery.log`, `m_chroot03_dracut.log`, `fix-listing.txt`
— captures from boot recovery sessions. Kept for future debugging reference.

## How recovery works

1. Boot fails → use m1n1/GRUB to add `init=/bin/bash` to kernel cmdline
2. Land at root shell (no services, no SELinux active yet)
3. `bash /home/wilfredor/m1-kernel/rescue/fix-asahi.sh`
4. `echo b > /proc/sysrq-trigger` to reboot

If `init=/bin/bash` doesn't work either, boot the Fedora rescue kernel and
use `diag.sh` to capture full state, then post-mortem from a working session.
