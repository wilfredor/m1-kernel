#!/bin/bash
# ============================================================================
# M1 WiFi Firmware Fix — persistent, idempotent
# Creates symlinks for kernel-expected brcmfmac firmware variant names.
#
# Problem: kernel 6.x brcmfmac iterates firmware suffixes the linux-firmware
# package does not ship (e.g. shikoku-RASP-u-6.5-X0.bin). Without these,
# "Direct firmware load for brcm/brcmfmac4378b1-pcie.sig failed".
#
# Solution: symlink each expected suffix to the base firmware file.
# Runs via systemd on every boot — survives linux-firmware package updates.
#
# Install:
#   sudo cp m1-wifi-firmware-fix.sh /usr/local/sbin/
#   sudo cp m1-wifi-firmware-fix.service /etc/systemd/system/
#   sudo systemctl enable --now m1-wifi-firmware-fix.service
# ============================================================================

set -u

FWDIR=/lib/firmware/brcm
SUFFIXES="-RASP-u-6.5-X0 -RASP-u-6.5 -RASP-u -RASP -X0"
EXTS=".bin .clm_blob .txcap_blob"
BOARDS="shikoku kyushu honshu santorini capri atlantisb"

cd "$FWDIR" 2>/dev/null || {
    echo "!!! $FWDIR missing — install linux-firmware-whence first" >&2
    exit 1
}

created=0

for board in $BOARDS; do
    for chip in 4378b1 4378b3; do
        BASE="brcmfmac${chip}-pcie.apple,${board}"

        # Binary + blob variants
        for ext in $EXTS; do
            [ -f "${BASE}${ext}" ] || continue
            for suf in $SUFFIXES; do
                TARGET="${BASE}${suf}${ext}"
                if [ ! -e "$TARGET" ]; then
                    ln -sf "${BASE}${ext}" "$TARGET"
                    created=$((created + 1))
                fi
            done
        done

        # .txt NVRAM — pick best available source
        TXT=""
        for src in "${BASE}-RASP-u.txt" "${BASE}.txt" "${BASE}-RASP-m.txt"; do
            [ -f "$src" ] && { TXT="$src"; break; }
        done
        [ -n "$TXT" ] || continue
        for suf in $SUFFIXES; do
            TARGET="${BASE}${suf}.txt"
            if [ ! -e "$TARGET" ]; then
                ln -sf "$(basename "$TXT")" "$TARGET"
                created=$((created + 1))
            fi
        done
    done
done

echo "m1-wifi-firmware-fix: created $created symlinks"
exit 0
