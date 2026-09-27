#!/usr/bin/env python3
"""End-to-end test of the Linux Mint Server ISO in QEMU/KVM.

  1. Boot the ISO through its own GRUB (BIOS and UEFI) and check the
     interactive installer comes up on the serial console.
  2. Unattended install (UEFI) onto a blank virtio disk via mintinstall.* args.
  3. Boot the installed disk under UEFI and under BIOS, log in over serial
     and assert the system is a headless Linux Mint server.

Usage: tests/qemu-test.py out/linuxmint-22.3-server-amd64.iso
Requires: qemu-system-x86_64, qemu-img, 7z, OVMF, python3-pexpect, /dev/kvm.
"""
import os
import shutil
import subprocess
import sys
import tempfile

import pexpect

ISO = os.path.abspath(sys.argv[1])
WORK = tempfile.mkdtemp(prefix="mint-server-test-")
DISK = os.path.join(WORK, "disk.qcow2")
OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = os.path.join(WORK, "OVMF_VARS.fd")
USER, PASSWORD, HOST = "tester", "Mint-test-1", "mintsrv"
LOGDIR = os.path.join(os.path.dirname(ISO), "test-logs")
os.makedirs(LOGDIR, exist_ok=True)

failures = []


def qemu(name, uefi, extra):
    args = ["-enable-kvm", "-cpu", "host", "-m", "4096", "-smp", "4",
            "-nographic", "-no-reboot",
            "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"]
    if uefi:
        # q35/AHCI: with OVMF on i440fx the IDE CD-ROM is not detected
        # under direct kernel boot.
        args += ["-machine", "q35"]
        args += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
                 "-drive", f"if=pflash,format=raw,file={OVMF_VARS}"]
    log = open(os.path.join(LOGDIR, f"{name}.log"), "w")
    child = pexpect.spawn("qemu-system-x86_64", args + extra, encoding="utf-8",
                          codec_errors="replace", timeout=600)
    child.logfile_read = log
    return child


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(label)


def stop(child):
    child.terminate(force=True)


def test_iso_boots(uefi):
    fw = "uefi" if uefi else "bios"
    print(f"\n== ISO boots to installer ({fw})")
    shutil.copy("/usr/share/OVMF/OVMF_VARS_4M.fd", OVMF_VARS)
    c = qemu(f"iso-{fw}", uefi, ["-cdrom", ISO, "-boot", "d"])
    try:
        c.expect("Install Linux Mint", timeout=120)
        check("GRUB menu shown", True)
        c.expect("Welcome to Linux Mint Server", timeout=300)
        check("installer launched on serial console", True)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        check(f"ISO boot ({fw})", False, type(e).__name__)
    finally:
        stop(c)


def test_install():
    print("\n== Unattended install (UEFI)")
    subprocess.run(["qemu-img", "create", "-f", "qcow2", DISK, "20G"], check=True,
                   stdout=subprocess.DEVNULL)
    shutil.copy("/usr/share/OVMF/OVMF_VARS_4M.fd", OVMF_VARS)
    kdir = os.path.join(WORK, "k")
    subprocess.run(["7z", "e", "-y", f"-o{kdir}", ISO, "casper/vmlinuz", "casper/initrd"],
                   check=True, stdout=subprocess.DEVNULL)
    append = ("boot=casper noprompt console=ttyS0,115200n8 mintinstall.auto "
              f"mintinstall.disk=/dev/vda mintinstall.user={USER} "
              f"mintinstall.password={PASSWORD} mintinstall.hostname={HOST} "
              "mintinstall.timezone=Europe/London mintinstall.finish=poweroff")
    c = qemu("install", True, [
        "-cdrom", ISO,
        "-drive", f"file={DISK},if=virtio,format=qcow2",
        "-kernel", f"{kdir}/vmlinuz", "-initrd", f"{kdir}/initrd", "-append", append])
    try:
        i = c.expect(["Installation complete", r"ERROR: .*"], timeout=1200)
        check("installer finished", i == 0, c.after if i else "")
        c.expect(pexpect.EOF, timeout=180)
        check("VM powered off", True)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        check("unattended install", False, type(e).__name__)
        stop(c)
        return False
    return i == 0


def run(c, cmd, timeout=120):
    marker = "__DONE__"
    c.sendline(f"{cmd}; echo {marker}$?")
    c.expect(rf"{marker}(\d+)", timeout=timeout)
    # Terminal echo and the prompt are off (see test_installed), so
    # everything before the marker is the command's output.
    return int(c.match.group(1)), c.before.strip()


def test_installed(uefi):
    fw = "uefi" if uefi else "bios"
    print(f"\n== Installed system ({fw})")
    c = qemu(f"installed-{fw}", uefi, ["-drive", f"file={DISK},if=virtio,format=qcow2"])
    try:
        c.expect(f"{HOST} login:", timeout=300)
        check("boots to text login (no display manager)", True)
        c.sendline(USER)
        c.expect("Password:")
        c.sendline(PASSWORD)
        c.expect(r"\$ ", timeout=60)
        c.sendline("stty -echo cols 200; PS1=''; export TERM=dumb PAGER=cat SYSTEMD_PAGER=cat")
        run(c, "true")

        rc, out = run(c, "systemctl get-default")
        check("default target is multi-user.target", out.endswith("multi-user.target"), out)
        rc, out = run(c, "systemctl is-enabled graphical.target")
        check("graphical.target is masked", "masked" in out, out)
        rc, out = run(c, "systemctl is-system-running --wait", timeout=180)
        check("no failed units", out.endswith("running"), out)
        if not out.endswith("running"):
            print(run(c, "systemctl --failed --no-legend")[1])
        rc, out = run(c, "grep ^PRETTY_NAME /etc/os-release")
        check("os-release is Linux Mint", "Linux Mint 22.3" in out, out)
        rc, out = run(c, "grep EDITION /etc/linuxmint/info")
        check("edition is Server", '"Server"' in out, out)
        rc, out = run(c, "dpkg-query -W -f '${db:Status-Abbrev} ${Package}\\n' | "
                         "awk '$1~/^i/{print $2}' | grep -E '^(xserver-xorg-core|xwayland|lightdm|gdm3|sddm|snapd|casper|cinnamon)$' || echo none")
        check("no X server / DM / snapd / casper", out == "none", out)
        rc, out = run(c, "apt-cache policy snapd | grep Candidate")
        check("snapd blocked by pin", "(none)" in out, out)
        rc, out = run(c, "type apt | head -1")
        check("Mint apt wrapper active", "/usr/local/bin/apt" in out, out)
        rc, out = run(c, "ls /etc/apt/sources.list.d/; grep -c packages.linuxmint.com /etc/apt/sources.list.d/official-package-repositories.list")
        check("Mint repo configured", rc == 0, out)
        # noble's sshd is socket-activated: ssh.service only runs per connection.
        rc, out = run(c, "systemctl is-active ssh.socket systemd-networkd | sort -u | tr '\\n' ' '")
        check("ssh socket + networkd active", out.strip() == "active", out)
        rc, out = run(c, "timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22; head -c 7 <&3'")
        check("sshd answers on :22", out.startswith("SSH-2.0"), out)
        rc, out = run(c, "ip -4 -o addr show scope global | awk '{print $4}'")
        check("DHCP address on wired NIC", out.startswith("10.0.2."), out)
        rc, out = run(c, f"echo {PASSWORD} | sudo -S -p '' ufw status | head -1")
        check("ufw active", "Status: active" in out, out)
        rc, out = run(c, f"echo {PASSWORD} | sudo -S -p '' apt-get update -qq && echo updated", timeout=300)
        check("apt update against Mint + Ubuntu repos", "updated" in out, out[-300:])
        rc, out = run(c, f"echo {PASSWORD} | sudo -S -p '' mintupdate-cli list 2>&1 | tail -3; echo rc=${{PIPESTATUS[1]}}", timeout=300)
        check("mintupdate-cli works", "Traceback" not in out and "rc=0" in out, out)
        rc, out = run(c, f"echo {PASSWORD} | sudo -S -p '' mintupdate-automation upgrade enable && systemctl list-timers --all --no-legend | grep -c mintupdate-automation")
        check("mintupdate-automation enable", rc == 0, out)
        rc, out = run(c, "timeshift --version")
        check("timeshift CLI present", rc == 0, out)
        rc, out = run(c, "inxi -S 2>&1 | head -2")
        check("inxi works", "Linux Mint" in out or "System:" in out, out)
        rc, out = run(c, "cat /etc/timezone; [ -e /usr/local/sbin/mint-server-install ] && echo LEAK || echo clean")
        check("timezone set, installer removed", "Europe/London" in out and "clean" in out, out)
        rc, out = run(c, "test -d /sys/firmware/efi && echo efi || echo bios")
        check(f"booted via {fw}", out == ("efi" if uefi else "bios"), out)
        run(c, f"echo {PASSWORD} | sudo -S -p '' systemctl poweroff")
        c.expect(pexpect.EOF, timeout=120)
    except (pexpect.TIMEOUT, pexpect.EOF) as e:
        check(f"installed system ({fw})", False, type(e).__name__)
        stop(c)


if __name__ == "__main__":
    only = set(sys.argv[2:])
    if not only or "iso" in only:
        test_iso_boots(uefi=False)
        test_iso_boots(uefi=True)
    if not only or "install" in only:
        if test_install():
            test_installed(uefi=True)
            test_installed(uefi=False)
    print(f"\nLogs: {LOGDIR}")
    shutil.rmtree(WORK, ignore_errors=True)
    if failures:
        print(f"{len(failures)} FAILED: " + ", ".join(failures))
        sys.exit(1)
    print("ALL PASSED")
