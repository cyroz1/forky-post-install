#!/usr/bin/env bash
# post-install setup for amir's debian forky dual boot
# main rig: ryzen 7 7800x3d, rx 7900 gre, gaming + dev (amd64)
# also runs on arm64 machines: arch-specific pieces branch below, and the
# handful of x86-only things (steam, thorium, 32-bit libs) skip cleanly
# instead of breaking the run.
# run AFTER first boot into debian:  chmod +x forky-post-install.sh && ./forky-post-install.sh
# if the install was done from the stable (trixie) image, this first upgrades
# the system to forky, then does the rest. safe to re-run, everything is
# idempotent. reboot when it finishes.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "run this as your normal user, it calls sudo itself." >&2
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) echo "==> architecture: $ARCH" ;;
  *) echo "unsupported architecture: $ARCH (this script handles amd64 and arm64)" >&2; exit 1 ;;
esac

# if we were piped in (curl | bash), $0 is not a real file and everything we
# launch shares stdin with the script itself, which corrupts the run (flatpak
# progress output fed back in as commands). save a real copy and re-exec it.
if [ ! -f "$0" ]; then
  curl -fsSL "https://raw.githubusercontent.com/cyroz1/forky-post-install/main/forky-post-install.sh" -o /tmp/forky-post-install.sh
  # hand stdin back to the real terminal: the pipe is exhausted by now, and
  # leaving it attached makes tmux die with "open terminal failed"
  if [ -e /dev/tty ]; then
    exec bash /tmp/forky-post-install.sh "$@" </dev/tty
  fi
  exec bash /tmp/forky-post-install.sh "$@"
fi

# survive a dying terminal window: run inside tmux. if the window closes,
# the session (and any apt upgrade inside it) keeps going. rejoin it with
#   tmux attach -t forky-setup
if [ -z "${TMUX:-}" ] && [ -z "${FORKY_SETUP_TMUX:-}" ]; then
  if [ ! -t 0 ]; then
    echo "==> no terminal on stdin, skipping the tmux wrapper"
  else
    if ! command -v tmux >/dev/null 2>&1; then
      sudo apt-get install -y tmux || true
    fi
    if command -v tmux >/dev/null 2>&1; then
      FORKY_SETUP_TMUX=1 exec tmux new-session -A -s forky-setup "bash '$0' $*; echo; echo '=== setup exited, press enter for a shell ==='; bash"
    fi
  fi
fi

echo "==> upgrade trixie to forky first, if this came from the stable image"
# the stable installer is the reliable way in; move the release up before
# installing anything so every package comes from forky
mapfile -t SRCFILES < <(grep -rl trixie /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
if [ "${#SRCFILES[@]}" -gt 0 ]; then
  sudo sed -i s/trixie/forky/g "${SRCFILES[@]}"
  # the installer's cdrom source points at the usb stick; disable it
  sudo sed -i 's|^deb cdrom|# deb cdrom|' "${SRCFILES[@]}"
  sudo apt update
  DEBIAN_FRONTEND=noninteractive sudo apt full-upgrade -y
  echo "==> release upgrade done, continuing on forky"
fi

echo "==> refreshing package lists"
sudo apt update

echo "==> making sure contrib + non-free + non-free-firmware are enabled"
# forky uses the deb822 sources file; this adds the components if they are missing
SOURCES=/etc/apt/sources.list.d/debian.sources
if [ -f "$SOURCES" ]; then
  sudo sed -i -E 's/^Components:.*$/Components: main contrib non-free non-free-firmware/' "$SOURCES"
fi
# classic one-line format: append any missing component at the end of the
# line (component order does not matter to apt). the old sed only added
# non-free-firmware when it was already there, so a main-only installer
# line stayed main-only and firmware packages had no candidate.
if [ -f /etc/apt/sources.list ]; then
  sudo sed -i -E '/^deb / { /non-free-firmware/! s|$| non-free-firmware|; / non-free /! s|$| non-free|; /contrib/! s|$| contrib| }' /etc/apt/sources.list
fi
sudo apt update

if [ "$ARCH" = "amd64" ]; then
  echo "==> 32-bit support (steam/wine need it)"
  sudo dpkg --add-architecture i386
  sudo apt update
else
  echo "==> skipping 32-bit (i386) support on $ARCH"
fi

echo "==> gpu firmware + mesa/vulkan"
# the firmware packages are for the main rig's physical hardware (amd gpu +
# mediatek wifi) and live on their own tolerant lines: a missing firmware
# package must never kill the run or take mesa down with it. mesa/vulkan
# exist on arm64 too; only the :i386 driver variants are amd64-only.
if [ "$ARCH" = "amd64" ]; then
  sudo apt install -y firmware-amd-graphics || echo "firmware-amd-graphics unavailable, skipping"
  sudo apt install -y firmware-mediatek || echo "firmware-mediatek unavailable, skipping"
  sudo apt install -y \
    mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
    libglx-mesa0 libglx-mesa0:i386 \
    libgl1-mesa-dri libgl1-mesa-dri:i386 \
    vulkan-tools
else
  echo "skipping amd/mediatek firmware on $ARCH (no such hardware there)"
  sudo apt install -y \
    mesa-vulkan-drivers \
    libglx-mesa0 \
    libgl1-mesa-dri \
    vulkan-tools
fi

echo "==> core anchors (desktop + networking must never go missing)"
# an interrupted upgrade + fix-broken churn once removed network-manager,
# dolphin and the sddm theme from a live system. installing them explicitly
# marks them manual, so no autoremove can ever orphan them away.
sudo apt install -y \
  kde-plasma-desktop sddm sddm-theme-breeze \
  network-manager plasma-nm wpasupplicant \
  dolphin konsole
# if systemd-networkd was used as a rescue bridge to get online, hand over
# to network-manager now that it exists again
if systemctl is-active --quiet systemd-networkd && ls /etc/systemd/network/10-*.network >/dev/null 2>&1; then
  sudo systemctl enable --now NetworkManager || true
  if systemctl is-active --quiet NetworkManager; then
    sudo systemctl disable --now systemd-networkd || true
    sudo rm -f /etc/systemd/network/10-wired.network /etc/systemd/network/10-wifi.network
  fi
fi

echo "==> vmware guest tools (only inside a vmware vm)"
# fusion on apple silicon gives arm linux guests no vmware-shipped tools, so
# integration (shared folders, clipboard, drag/drop, display auto-resize)
# runs on open-vm-tools. detect the hypervisor, not the arch, so an amd64
# vm gets it too and bare metal skips it.
if [ "$(systemd-detect-virt 2>/dev/null || true)" = "vmware" ]; then
  sudo apt install -y open-vm-tools open-vm-tools-desktop || echo "open-vm-tools unavailable in this release, skipping"
else
  echo "not a vmware guest, skipping"
fi

echo "==> basics + dev tools"
sudo apt install -y \
  git curl wget ffmpeg fastfetch \
  build-essential obs-studio \
  gamemode mangohud
# gamescope is not in trixie (it is in forky); never let it kill the run
sudo apt install -y gamescope || echo "gamescope unavailable in this release, skipping"

echo "==> media players + utilities (replacing the kde defaults)"
# video: vlc + mpv, haruna is the kde-native mpv frontend
# music: strawberry. utilities: qbittorrent, audacity, kid3 (tag editor),
# mediainfo, yt-dlp. all verified present in forky.
sudo apt install -y \
  vlc mpv haruna strawberry \
  qbittorrent audacity kid3 mediainfo yt-dlp
# the kde defaults these replace; fine if one is not installed
sudo apt remove -y dragonplayer elisa juk ktorrent || true

echo "==> ssd trim (weekly, usually on by default, make sure)"
sudo systemctl enable --now fstrim.timer || true

echo "==> flatpak + flathub"
sudo apt install -y flatpak
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

if [ "$ARCH" = "amd64" ]; then
  echo "==> steam (flatpak) + mangohud overlay for it"
  # --system pinned: serein's flatpakref adds a user-level flathub, and with
  # flathub in both installations flatpak stops to ask which one (and aborts)
  flatpak install --system -y flathub com.valvesoftware.Steam </dev/null
  flatpak install --system -y flathub org.freedesktop.Platform.VulkanLayer.MangoHud//24.08 </dev/null || \
    echo "mangohud flatpak layer failed, steam still works, native mangohud is installed for native games"
else
  echo "==> skipping steam on $ARCH: the flathub steam build is x86_64 only"
  echo "    (native arm64 games still get the apt gamemode + mangohud installed above;"
  echo "     running x86 steam on arm64 needs fex/box64 emulation, not set up here)"
fi

echo "==> serein (native discord client, flatpak from the project's own repo)"
flatpak install --user -y https://viceverse-cz.github.io/Serein/flatpak/serein.flatpakref </dev/null || \
  echo "serein flatpak install failed, grab it later from the serein github releases"

if [ "$ARCH" = "amd64" ]; then
  echo "==> thorium browser (from thorium's own apt repo)"
  sudo wget --no-hsts -P /etc/apt/sources.list.d/ https://dl.thorium.rocks/debian/dists/stable/thorium.list
  sudo apt update
  sudo apt install -y thorium-browser
else
  echo "==> skipping thorium on $ARCH: its apt repo is amd64 only, installing chromium instead"
  sudo apt install -y chromium || echo "chromium unavailable in this release, skipping"
fi

echo "==> chatgpt (official .deb) + codex cli"
# chatgpt desktop app for linux is official now (preview): openai's own .deb, it also sets up their signed repo for updates
# their support list names debian 13; forky is testing (future 14), should work but is not formally listed
# openai publishes the chatgpt .deb for both amd64 and arm64 (same url pattern, arch swapped)
# codex: openai ships no .deb for the standalone cli; on amd64 this installs the deb on your
# forky-post-install repo's releases, which wraps their official 0.166.0 linux binary. there is
# no arm64 version of that deb, so on arm64 it installs openai's official aarch64 musl tarball
# from the openai/codex github release straight into /usr/local/bin instead.
if [ "$ARCH" = "amd64" ]; then
  wget -O /tmp/chatgpt_amd64.deb https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
  wget -O /tmp/openai-codex.deb https://github.com/cyroz1/forky-post-install/releases/latest/download/openai-codex_0.166.0_amd64.deb
  sudo apt install -y /tmp/chatgpt_amd64.deb /tmp/openai-codex.deb
else
  wget -O /tmp/chatgpt_arm64.deb https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_arm64.deb
  sudo apt install -y /tmp/chatgpt_arm64.deb
  wget -O /tmp/codex-aarch64.tar.gz https://github.com/openai/codex/releases/download/rust-v0.166.0/codex-aarch64-unknown-linux-musl.tar.gz
  rm -rf /tmp/codex-aarch64 && mkdir -p /tmp/codex-aarch64
  tar -xzf /tmp/codex-aarch64.tar.gz -C /tmp/codex-aarch64
  CODEX_BIN="$(find /tmp/codex-aarch64 -type f -name 'codex-*' | head -1)"
  if [ -n "$CODEX_BIN" ]; then
    sudo install -m 0755 "$CODEX_BIN" /usr/local/bin/codex
  else
    echo "codex binary not found inside the aarch64 tarball, grab it manually from the openai/codex releases" >&2
  fi
fi

echo "==> optimize + debloat"
# startup services a gaming desktop does not need. all reversible with
# systemctl enable. (bluetooth and wifi deliberately left alone)
for svc in ModemManager avahi-daemon avahi-daemon.socket cups cups-browsed cups.socket NetworkManager-wait-online; do
  sudo systemctl disable --now "$svc" 2>/dev/null || true
done
# kde file indexer, the classic background hog
balooctl6 disable 2>/dev/null || balooctl disable 2>/dev/null || true
# make sure the file manager is actually there and marked manual, so
# autoremove can never eat it (an interrupted upgrade can orphan it)
sudo apt install -y dolphin
# orphaned packages + leftover configs from everything installed above,
# plus the downloaded .deb cache (gigabytes after a release upgrade)
# heal anything half-configured first and re-anchor the core before any
# removal pass, and no --purge: a leftover config file is harmless, a
# wrongly purged package is not.
sudo dpkg --configure -a
sudo apt --fix-broken install -y
sudo apt install -y kde-plasma-desktop network-manager dolphin
sudo apt autoremove -y
sudo apt clean
# 32gb of ram: swap is a last resort, not a scratchpad
echo "vm.swappiness=10" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
sudo sysctl -w vm.swappiness=10 >/dev/null
# cap how much disk the systemd journal can grow to
sudo mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\n' | sudo tee /etc/systemd/journald.conf.d/99-size-cap.conf >/dev/null
# quick dual boot menu
if [ -f /etc/default/grub ]; then
  sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
  sudo update-grub
fi

# ---------------------------------------------------------------------------
# clock fight fix (windows uses local time, linux defaults to utc)
# pick ONE side only. the install guide had you do the windows registry fix.
# if you did that, leave this commented out. if you did NOT, uncomment:
#
# timedatectl set-local-rtc 1
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# optional: LACT, amd gpu control panel (fan curves, clocks, power limit)
# (the download grep below only matches the amd64 .deb; skip this block on arm64)
# uncomment to grab the latest .deb from github:
#
# LACT_DEB=$(curl -s https://api.github.com/repos/ilya-zlobintsev/LACT/releases/latest \
#   | grep -o '"browser_download_url": *"[^"]*amd64\.deb"' | head -1 | cut -d'"' -f4)
# if [ -n "$LACT_DEB" ]; then
#   wget -O /tmp/lact.deb "$LACT_DEB"
#   sudo apt install -y /tmp/lact.deb
#   sudo systemctl enable --now lactd
# fi
# ---------------------------------------------------------------------------

echo "==> sanity check"
missing=""
for cmd in dolphin konsole codex; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
systemctl cat NetworkManager.service >/dev/null 2>&1 || missing="$missing network-manager"
if [ -n "$missing" ]; then
  echo "WARNING, still missing:$missing" >&2
  echo "re-run this script once you are back online and it will fill the gaps" >&2
else
  echo "core pieces all present: desktop, file manager, terminal, networking"
fi

echo
echo "done. reboot, then check the gpu stack with:  vulkaninfo --summary | grep -A2 deviceName"
echo "in steam: set launch options per game to  mangohud gamemoderun %command%  (flatpak steam: mangohud works via the vulkan layer)"
