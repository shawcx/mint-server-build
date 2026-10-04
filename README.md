# Mint Server (unofficial)

> **This is an independent, community build. It is not produced, endorsed or
> supported by the Linux Mint project or Clement Lefebvre.** "Linux Mint" is a
> trademark of the Linux Mint project. "Linux" is a registered trademark of
> Linus Torvalds. Please do not report problems with this build to the Linux
> Mint forums or bug trackers; report them at
> <https://github.com/shawcx/mint-server-build/issues> instead.

A headless, server-oriented build based on Linux Mint 22.3 (Zena, Ubuntu 24.04
base). It builds a bootable hybrid BIOS/UEFI installer ISO. The installed
system boots to `multi-user.target`: no X server, Wayland compositor, display
manager or desktop. It keeps the Linux Mint parts that make sense on a server.

Everything user-facing (GRUB, ISO label, installer, MOTD, `EDITION` in
`/etc/linuxmint/info`) says "Mint Server (unofficial)" so nobody mistakes it
for an official edition. `/etc/os-release` is Mint's own `base-files` and
still reports "Linux Mint 22.3", because `mintupdate-cli` and other Mint
tools key off it.

## What you get

| Area | Details |
|---|---|
| Base | Ubuntu noble + `packages.linuxmint.com zena`, with Mint's pinning (`o=linuxmint,c=upstream` at 700) so Mint's `base-files` etc. win |
| Mint tools | Mint `apt` wrapper, `mintupdate-cli`, `mintupdate-automation` (+ timers), `timeshift`, `inxi`, `mint-mirrors`, `mint-upgrade-info`, `linuxmint-keyring` |
| Identity | `/etc/os-release` = Linux Mint 22.3 (from Mint's `base-files`), `/etc/linuxmint/info` `EDITION="Server (unofficial)"`, GRUB entry "Mint Server (unofficial) 22.3", MOTD help text stating the build is unofficial (Ubuntu motd-news off) |
| No GUI | `multi-user.target` default, `graphical.target` masked, APT pins block X/Wayland servers, display managers and desktop metapackages (`mint-server-no-gui.pref`), and the build fails if any turn up (`config/forbidden.list`) |
| No snap | Mint's `nosnap.pref` |
| Server defaults | OpenSSH (unique host keys per install), `ufw` on (deny in, allow SSH), `unattended-upgrades`, netplan + systemd-networkd (DHCP on all wired NICs), `needrestart`, swap file, serial console on `ttyS0` + `tty0` |
| Boot | GRUB installed for **both** BIOS (`i386-pc`) and UEFI (signed shim + removable path), so a disk boots in either mode |

### How the Mint tools stay headless

Upstream `mintsystem` and `mintupdate` depend on GTK, zenity and `mint-common`.
The build downloads those two `.deb`s from the Mint repo and repackages only
their CLI parts into a local **`mint-server-base`** package
(`scripts/chroot/build-mint-server-base.sh`). It owns the server config
(pins, MOTD, ssh drop-in, GRUB defaults, `/etc/linuxmint/info`) as
conffiles. It `Conflicts/Replaces` `mintsystem`/`mintupdate`/`mint-info-*`, so
installing a Mint desktop later swaps it out cleanly (after you delete
`/etc/apt/preferences.d/mint-server-no-gui.pref`).

`mint-server-base` is baked into the ISO, so it does not auto-update when Mint
updates `mintsystem`/`mintupdate`. Rebuild to pick those changes up. The
`.deb` is also copied to `out/` if you want to host it in your own repo.

`timeshift` links GTK libraries (Mint doesn't build a CLI-only variant). It
pulls in libraries only, no display server. Remove it from
`config/packages.server` if you'd rather not have them.

## Building

Requirements: Docker. The build runs in a privileged container, so the host
needs no sudo or extra tools.

```sh
./build.sh
# -> out/mint-server-unofficial-22.3-amd64.iso (+ .sha256, .manifest, mint-server-base_*.deb)
```

Tweak `config/build.conf` (mirrors, kernel flavour, masking, ISO name) and
`config/packages.server` (package set). APT and debootstrap downloads are
cached in `work/cache/`, so rebuilds are fast.

### CI

`.gitlab-ci.yml` builds the ISO on the `amd64` GitLab runner (Docker executor) by running `build.sh` against the host's Docker daemon. The runner's `config.toml` needs `volumes = ["/cache", "/var/run/docker.sock:/var/run/docker.sock", "/srv/mint-server:/srv/mint-server"]` under `[runners.docker]`. `work/` persists in `/srv/mint-server/src` on the runner host, so its apt and debootstrap caches carry over between runs. ISOs are uploaded to the project's generic package registry as `mint-server-unofficial/22.3-<pipeline iid>`. The QEMU test isn't run in CI because it needs KVM.

## Installing

Boot the ISO. The installer starts automatically on `tty1` and on the serial
console. It asks for a disk (erased), hostname, admin user and password,
an optional SSH key, and a timezone. The layout is GPT: 1 MiB BIOS boot,
512 MiB ESP, ext4 root, plus a 2 GiB `/swap.img`.

"Live rescue shell" in the boot menu gives a root shell without the installer.
Secure Boot must be off to boot the ISO itself (its GRUB is unsigned). The
installed system uses Ubuntu's signed shim/GRUB.

### Unattended install

At the ISO's GRUB menu press `e` and append to the `linux` line:

```
mintinstall.auto mintinstall.disk=/dev/sda mintinstall.password_hash=$6$... \
mintinstall.hostname=srv01 mintinstall.user=admin mintinstall.timezone=Etc/UTC \
mintinstall.swap=2G mintinstall.finish=reboot
```

(`mintinstall.password=` also works for testing.) See the header of
`live-overlay/usr/local/sbin/mint-server-install` for the full list.

## After install

```sh
sudo mintupdate-cli upgrade                  # Mint-style updates (Mint + Ubuntu)
sudo mintupdate-automation upgrade enable    # daily automatic updates (Mint's way)
sudo timeshift --create                      # snapshot
apt search foo                               # Mint's apt wrapper
```

## Testing

```sh
tests/qemu-test.py out/mint-server-unofficial-22.3-amd64.iso
```

Boots the ISO under BIOS and UEFI, does an unattended UEFI install into a
qcow2 disk, then boots the result under UEFI **and** BIOS and checks the
default target, masked `graphical.target`, absence of X/DM/snap/casper,
unofficial edition identity, repos, `apt` wrapper, `mintupdate-cli`, ufw, ssh, DHCP and more.
Needs KVM, OVMF, `7z` and `python3-pexpect`. Serial logs go to `out/test-logs/`.

## Layout

```
build.sh                         host entrypoint (docker)
Dockerfile                       build environment
config/                          release settings, package lists, forbidden list, Mint key
scripts/build-in-container.sh    debootstrap -> configure -> squashfs -> ISO
scripts/chroot/                  runs inside the chroot (mint-server-base assembly)
packages/mint-server-base/       static files + DEBIAN metadata for mint-server-base
live-overlay/                    live-session only: installer, autologin, autoinstall unit
iso/grub.cfg                     ISO boot menu
tests/qemu-test.py               end-to-end QEMU test
```

## Credits and license

The build scripts, installer, package lists and `mint-server-base` packaging
in this repository are copyright 2026 Matthew Shaw and released under the
GNU General Public License, version 3 or later. See `LICENSE`.

The operating system it produces is assembled from unmodified Ubuntu and
Linux Mint packages, fetched at build time from their official repositories.
`mint-server-base` repackages the command-line parts of Mint's `mintsystem`
(GPL-2+) and `mintupdate` (GPL-3+), both copyright Clement Lefebvre; the
per-file breakdown is in
`packages/mint-server-base/root/usr/share/doc/mint-server-base/copyright`
and ships in the installed system.

Linux Mint is at <https://linuxmint.com>. This project is not affiliated
with it.
