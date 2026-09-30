# Live session only: launch the installer on the primary consoles.
[ -f ~/.bashrc ] && . ~/.bashrc
if ! grep -qwE 'mintinstall=off|mintinstall\.auto' /proc/cmdline; then
    case "$(tty)" in
        /dev/tty1|/dev/ttyS0) /usr/local/sbin/mint-server-install ;;
    esac
fi
echo
echo "Mint Server (unofficial) live session. Run 'mint-server-install' to install."
