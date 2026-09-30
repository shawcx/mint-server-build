#!/bin/bash
# Runs INSIDE the target chroot. Assembles the mint-server-base .deb from:
#   - static files in /tmp/msb/src (packages/mint-server-base)
#   - the headless parts of Mint's mintsystem and mintupdate packages,
#     downloaded from the Mint repo so they track upstream.
# Output: /tmp/msb/mint-server-base_<version>_all.deb
set -euo pipefail

: "${MINT_RELEASE:?}" "${MINT_CODENAME:?}" "${MINT_CODENAME_PRETTY:?}"

W=/tmp/msb
SRC=$W/src
EXT=$W/ext
PKG=$W/pkg
rm -rf "$EXT" "$PKG"
mkdir -p "$EXT" "$PKG"

cd "$W"
rm -f ./*.deb
apt-get download mintsystem mintupdate
for deb in mintsystem_*.deb mintupdate_*.deb; do
    dpkg-deb -x "$deb" "$EXT"
done
MINTSYSTEM_VERSION=$(dpkg-deb -f mintsystem_*.deb Version)
MINTUPDATE_VERSION=$(dpkg-deb -f mintupdate_*.deb Version)

cp -a "$SRC/root/." "$PKG/"

# Copy a path (file or dir) from the extracted upstream packages, keeping layout.
take() {
    local p
    for p in "$@"; do
        if [ ! -e "$EXT/$p" ]; then
            echo "build-mint-server-base: upstream file missing: $p" >&2
            exit 1
        fi
        mkdir -p "$PKG/$(dirname "$p")"
        cp -a "$EXT/$p" "$PKG/$p"
    done
}

# --- from mintsystem: APT wrapper and helpers (no GTK / zenity parts) ---
take usr/local/bin/apt \
     usr/local/bin/highlight-mint \
     usr/lib/linuxmint/mintsystem/mint-apt-download.py \
     usr/lib/linuxmint/mintsystem/mint-apt-recommends.py \
     usr/share/linuxmint/mintsystem/apt \
     etc/bash_completion.d/apt-linux-mint \
     etc/apt/apt.conf.d/90mintsystem \
     etc/apt/preferences.d/official-extra-repositories.pref \
     etc/sudoers.d/0pwfeedback

# --- from mintupdate: CLI + automation (no GUI, tray, polkit or autostart) ---
take usr/bin/mintupdate-cli \
     usr/bin/mintupdate-automation \
     usr/lib/linuxmint/mintUpdate/Classes.py \
     usr/lib/linuxmint/mintUpdate/checkAPT.py \
     usr/lib/linuxmint/mintUpdate/mintupdate-cli.py \
     usr/lib/linuxmint/mintUpdate/automatic_upgrades.py \
     usr/lib/linuxmint/mintUpdate/logger.py \
     usr/lib/linuxmint/mintUpdate/dpkg_lock_check.sh \
     usr/lib/linuxmint/mintUpdate/aliases \
     usr/share/linuxmint/mintupdate/automation \
     usr/share/glib-2.0/schemas/com.linuxmint.updates.gschema.xml \
     usr/share/python-apt/templates/LinuxMint.info \
     usr/share/man/man8/mintupdate-cli.8.gz \
     etc/logrotate.d/mintupdate
for unit in "$EXT"/lib/systemd/system/mintupdate-automation-*; do
    mkdir -p "$PKG/usr/lib/systemd/system"
    cp -a "$unit" "$PKG/usr/lib/systemd/system/"
done
# Automation touchfiles are toggled by mintupdate-automation; the timers are
# enabled statically so the touchfile alone controls whether upgrades run.
mkdir -p "$PKG/usr/lib/systemd/system/timers.target.wants"
for t in "$PKG"/usr/lib/systemd/system/mintupdate-automation-*.timer; do
    ln -s "../$(basename "$t")" "$PKG/usr/lib/systemd/system/timers.target.wants/$(basename "$t")"
done

# --- Server edition identity (clearly marked unofficial: not a Linux Mint product) ---
mkdir -p "$PKG/etc/linuxmint"
cat > "$PKG/etc/linuxmint/info" <<EOF
RELEASE=${MINT_RELEASE}
CODENAME=${MINT_CODENAME}
EDITION="Server (unofficial)"
DESCRIPTION="Mint Server (unofficial) ${MINT_RELEASE} ${MINT_CODENAME_PRETTY}"
DESKTOP=None
TOOLKIT=None
NEW_FEATURES_URL=https://www.linuxmint.com/rel_${MINT_CODENAME}_whatsnew.php
RELEASE_NOTES_URL=https://www.linuxmint.com/rel_${MINT_CODENAME}.php
USER_GUIDE_URL=https://www.linuxmint.com/documentation.php
GRUB_TITLE="Mint Server (unofficial) ${MINT_RELEASE}"
EOF

mkdir -p "$PKG/etc/default/grub.d"
cat > "$PKG/etc/default/grub.d/50_linuxmint-server.cfg" <<EOF
# Mint Server (unofficial): text boot, visible kernel messages, serial-friendly.
GRUB_DISTRIBUTOR="Mint Server (unofficial) ${MINT_RELEASE}"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 console=tty0"
EOF

# --- DEBIAN metadata ---
mkdir -p "$PKG/DEBIAN"
VERSION="${MINT_RELEASE}.$(date -u +%Y%m%d%H%M)"
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@MINTSYSTEM_VERSION@/$MINTSYSTEM_VERSION/" \
    -e "s/@MINTUPDATE_VERSION@/$MINTUPDATE_VERSION/" \
    "$SRC/DEBIAN/control.in" > "$PKG/DEBIAN/control"
install -m 755 "$SRC/DEBIAN/postinst" "$SRC/DEBIAN/postrm" "$PKG/DEBIAN/"
(cd "$PKG" && find etc -type f | sed 's|^|/|' | sort) > "$PKG/DEBIAN/conffiles"
chmod 440 "$PKG/etc/sudoers.d/0pwfeedback"

dpkg-deb --root-owner-group --build "$PKG" "$W/mint-server-base_${VERSION}_all.deb"
echo "built $W/mint-server-base_${VERSION}_all.deb (mintsystem $MINTSYSTEM_VERSION, mintupdate $MINTUPDATE_VERSION)"
