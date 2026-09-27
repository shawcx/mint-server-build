#!/bin/bash
# Builds the Linux Mint Server live/installer ISO. Runs as root inside the
# privileged build container started by ./build.sh.
#
#   work/chroot   the server root filesystem (+ casper for the live session)
#   work/iso      ISO tree (casper/, boot/grub/, .disk/)
#   out/          final ISO + manifest
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../config/build.conf
. "$TOP/config/build.conf"

WORK=$TOP/work
OUT=$TOP/out
CHROOT=$WORK/chroot
ISO=$WORK/iso
CACHE=$WORK/cache

export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

list() { grep -Ev '^\s*(#|$)' "$1" | awk '{print $1}'; }

in_chroot() { chroot "$CHROOT" /usr/bin/env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LC_ALL=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive "$@"; }

MOUNTS=()
mount_chroot() {
    local m
    for m in proc sys dev dev/pts run; do mkdir -p "$CHROOT/$m"; done
    mount -t proc proc "$CHROOT/proc";            MOUNTS+=("$CHROOT/proc")
    mount -t sysfs sys "$CHROOT/sys";             MOUNTS+=("$CHROOT/sys")
    mount --bind /dev "$CHROOT/dev";              MOUNTS+=("$CHROOT/dev")
    mount -t devpts devpts "$CHROOT/dev/pts";     MOUNTS+=("$CHROOT/dev/pts")
    mount -t tmpfs tmpfs "$CHROOT/run";           MOUNTS+=("$CHROOT/run")
    mkdir -p "$CACHE/apt" "$CHROOT/var/cache/apt/archives"
    mount --bind "$CACHE/apt" "$CHROOT/var/cache/apt/archives"
    MOUNTS+=("$CHROOT/var/cache/apt/archives")
}
umount_chroot() {
    local i
    for (( i=${#MOUNTS[@]}-1; i>=0; i-- )); do
        umount -l "${MOUNTS[$i]}" 2>/dev/null || true
    done
    MOUNTS=()
}
trap umount_chroot EXIT

# ---------------------------------------------------------------------------
log "Preparing work tree"
umount_chroot
if [ -d "$CHROOT" ]; then
    # Never rm -rf through a live bind mount.
    grep -q " $CHROOT/" /proc/mounts && { echo "stale mounts under $CHROOT"; exit 1; }
    rm -rf "$CHROOT"
fi
rm -rf "$ISO"
mkdir -p "$CHROOT" "$ISO" "$OUT" "$CACHE/debootstrap" "$CACHE/apt"

# ---------------------------------------------------------------------------
log "debootstrap $UBUNTU_CODENAME ($ARCH)"
debootstrap --arch="$ARCH" --variant=minbase \
    --components=main,restricted,universe,multiverse \
    --cache-dir="$CACHE/debootstrap" \
    "$UBUNTU_CODENAME" "$CHROOT" "$UBUNTU_MIRROR"

mount_chroot

# Keep services from starting inside the chroot.
cat > "$CHROOT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 755 "$CHROOT/usr/sbin/policy-rc.d"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf.build"
rm -f "$CHROOT/etc/resolv.conf"
cp "$CHROOT/etc/resolv.conf.build" "$CHROOT/etc/resolv.conf"

# ---------------------------------------------------------------------------
log "Configuring Linux Mint + Ubuntu repositories"
rm -f "$CHROOT/etc/apt/sources.list"
cat > "$CHROOT/etc/apt/sources.list.d/official-package-repositories.list" <<EOF
# Linux Mint ${MINT_RELEASE} Server

deb ${MINT_MIRROR} ${MINT_CODENAME} main upstream import backport #id:linuxmint_main

deb ${UBUNTU_MIRROR} ${UBUNTU_CODENAME} main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_CODENAME}-backports main restricted universe multiverse

deb ${UBUNTU_SECURITY_MIRROR} ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
install -m 644 "$TOP/config/keys/linuxmint-keyring.gpg" \
    "$CHROOT/etc/apt/trusted.gpg.d/linuxmint-keyring.gpg"
# Pinning must be active before the first install so Mint's packages
# (base-files etc.) win; mint-server-base takes ownership of these later.
cp "$TOP"/packages/mint-server-base/root/etc/apt/preferences.d/*.pref \
    "$CHROOT/etc/apt/preferences.d/"
cp "$TOP/packages/mint-server-base/root/etc/apt/apt.conf.d/99mint-server" \
    "$CHROOT/etc/apt/apt.conf.d/"

in_chroot apt-get update
in_chroot apt-get -y -o Dpkg::Options::=--force-confnew full-upgrade

# ---------------------------------------------------------------------------
log "Installing server packages"
# Kernel postinst hooks need these present first.
in_chroot apt-get -y install --no-install-recommends initramfs-tools locales
echo "${DEFAULT_LOCALE} ${DEFAULT_LOCALE#*.}" > "$CHROOT/etc/locale.gen"
in_chroot locale-gen
echo "LANG=${DEFAULT_LOCALE}" > "$CHROOT/etc/default/locale"

# shellcheck disable=SC2046
in_chroot apt-get -y install --no-install-recommends \
    -o Dpkg::Options::=--force-confnew \
    $(list "$TOP/config/packages.server") "$KERNEL_PACKAGE"

log "Building mint-server-base"
rm -rf "$CHROOT/tmp/msb"
mkdir -p "$CHROOT/tmp/msb"
cp -a "$TOP/packages/mint-server-base" "$CHROOT/tmp/msb/src"
install -m 755 "$TOP/scripts/chroot/build-mint-server-base.sh" "$CHROOT/tmp/msb/"
in_chroot MINT_RELEASE="$MINT_RELEASE" MINT_CODENAME="$MINT_CODENAME" \
    MINT_CODENAME_PRETTY="$MINT_CODENAME_PRETTY" /tmp/msb/build-mint-server-base.sh
in_chroot sh -c 'apt-get -y install --no-install-recommends \
    -o Dpkg::Options::=--force-confnew /tmp/msb/mint-server-base_*_all.deb'
mkdir -p "$OUT"
cp "$CHROOT"/tmp/msb/mint-server-base_*_all.deb "$OUT/"
rm -rf "$CHROOT/tmp/msb"

# ---------------------------------------------------------------------------
log "Configuring the server system"
in_chroot systemctl set-default multi-user.target
if [ "$MASK_GRAPHICAL_TARGET" = yes ]; then
    in_chroot systemctl mask graphical.target
fi
in_chroot systemctl mask motd-news.timer
in_chroot ln -sf "/usr/share/zoneinfo/$DEFAULT_TIMEZONE" /etc/localtime
echo "$DEFAULT_TIMEZONE" > "$CHROOT/etc/timezone"

# Firewall: on, deny inbound except SSH.
sed -i 's/^ENABLED=.*/ENABLED=yes/' "$CHROOT/etc/ufw/ufw.conf"
in_chroot ufw --force default deny incoming >/dev/null
in_chroot ufw allow OpenSSH >/dev/null || true
# ufw refuses rule edits when it can't talk to the kernel; write the rule directly
# if needed.
if ! grep -q 'dport 22 ' "$CHROOT/etc/ufw/user.rules"; then
    sed -i '/^### RULES ###/a\
\
### tuple ### allow tcp 22 0.0.0.0/0 any 0.0.0.0/0 OpenSSH - in\
-A ufw-user-input -p tcp --dport 22 -j ACCEPT -m comment --comment '"'"'dapp_OpenSSH'"'"'' \
        "$CHROOT/etc/ufw/user.rules"
fi

echo "mint-server" > "$CHROOT/etc/hostname"
cat > "$CHROOT/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 mint-server

::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# ---------------------------------------------------------------------------
log "Guard: no graphical stack"
bad=$(in_chroot dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' \
      | awk '$1 ~ /^i/ {print $2}' \
      | grep -Ex "$(list "$TOP/config/forbidden.list" | paste -sd'|')" || true)
if [ -n "$bad" ]; then
    echo "Forbidden packages installed:" >&2
    echo "$bad" >&2
    exit 1
fi
echo "ok"

# Snapshot the server package set before live-only additions.
in_chroot dpkg-query -W -f '${Package}\t${Version}\n' > "$WORK/filesystem.manifest.server"

# ---------------------------------------------------------------------------
log "Adding live session + installer"
# shellcheck disable=SC2046
in_chroot apt-get -y install --no-install-recommends $(list "$TOP/config/packages.live")
cat > "$CHROOT/etc/casper.conf" <<EOF
export USERNAME="mint"
export USERFULLNAME="Live session user"
export HOST="mint-server"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="Linux Mint"
EOF
cp -a "$TOP/live-overlay/." "$CHROOT/"
(cd "$TOP/live-overlay" && find . -type f -o -type l | sed 's|^\.||' | sort) \
    > "$CHROOT/usr/share/mint-server-install/live-files"
list "$TOP/config/packages.live" > "$CHROOT/usr/share/mint-server-install/live-packages"
chmod 755 "$CHROOT/usr/local/sbin/mint-server-install"
in_chroot systemctl enable mint-server-autoinstall.service

# ---------------------------------------------------------------------------
log "Cleaning image"
rm -f "$CHROOT/usr/sbin/policy-rc.d"
rm -f "$CHROOT"/etc/ssh/ssh_host_*
: > "$CHROOT/etc/machine-id"
rm -f "$CHROOT/var/lib/dbus/machine-id"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
rm -f "$CHROOT/etc/resolv.conf.build"
in_chroot update-initramfs -u -k all
in_chroot apt-get clean
umount_chroot
rm -rf "$CHROOT"/var/lib/apt/lists/* "$CHROOT"/tmp/* "$CHROOT"/var/tmp/*
mkdir -p "$CHROOT/var/lib/apt/lists/partial"
find "$CHROOT/var/log" -type f -exec truncate -s0 {} +

# ---------------------------------------------------------------------------
log "Assembling ISO tree"
mkdir -p "$ISO/casper" "$ISO/boot/grub" "$ISO/.disk"
KVER=$(basename "$(ls -d "$CHROOT"/lib/modules/* | sort -V | tail -1)")
cp "$CHROOT/boot/vmlinuz-$KVER" "$ISO/casper/vmlinuz"
cp "$CHROOT/boot/initrd.img-$KVER" "$ISO/casper/initrd"

chroot "$CHROOT" dpkg-query -W -f '${Package}\t${Version}\n' > "$ISO/casper/filesystem.manifest"
cut -f1 "$ISO/casper/filesystem.manifest" | sort > "$WORK/all.pkgs"
cut -f1 "$WORK/filesystem.manifest.server" | sort > "$WORK/server.pkgs"
comm -23 "$WORK/all.pkgs" "$WORK/server.pkgs" > "$ISO/casper/filesystem.manifest-remove"

mksquashfs "$CHROOT" "$ISO/casper/filesystem.squashfs" \
    -noappend -comp zstd -Xcompression-level 19 -b 1M \
    -e boot/efi -wildcards -e 'proc/*' -e 'sys/*' -e 'dev/*' -e 'run/*'
du -sx --block-size=1 "$CHROOT" | cut -f1 > "$ISO/casper/filesystem.size"

echo "Linux Mint ${MINT_RELEASE} \"${MINT_CODENAME_PRETTY}\" - Server ${ARCH} ($(date -u +%Y%m%d))" > "$ISO/.disk/info"
sed -e "s/@MINT_RELEASE@/$MINT_RELEASE/g" "$TOP/iso/grub.cfg" > "$ISO/boot/grub/grub.cfg"

log "Building hybrid BIOS/UEFI ISO"
grub-mkrescue -o "$OUT/$ISO_NAME" "$ISO" -- -volid "$ISO_LABEL"
cp "$ISO/casper/filesystem.manifest" "$OUT/${ISO_NAME%.iso}.manifest"
(cd "$OUT" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256")

if [ -n "${HOST_UID:-}" ]; then
    chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$OUT"
fi
log "Done: $OUT/$ISO_NAME ($(du -h "$OUT/$ISO_NAME" | cut -f1))"
