#!/usr/bin/env bash
# post-install setup for amir's debian forky dual boot
# rig: ryzen 7 7800x3d, rx 7900 gre, gaming + dev
# run AFTER first boot into debian:  chmod +x forky-post-install.sh && ./forky-post-install.sh
# if the install was done from the stable (trixie) image, this first upgrades
# the system to forky, then does the rest. safe to re-run, everything is
# idempotent. reboot when it finishes.

set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "run this as your normal user, it calls sudo itself." >&2
  exit 1
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
# classic one-line format: add contrib + non-free where they are missing
if [ -f /etc/apt/sources.list ]; then
  sudo sed -i -E '/^deb / { /contrib/! s| main| contrib main|; / non-free /! s| non-free-firmware| non-free non-free-firmware| }' /etc/apt/sources.list
fi
sudo apt update

echo "==> 32-bit support (steam/wine need it)"
sudo dpkg --add-architecture i386
sudo apt update

echo "==> amd gpu firmware + mesa/vulkan (7900 gre)"
sudo apt install -y \
  firmware-amd-graphics \
  firmware-mediatek \
  mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
  libglx-mesa0 libglx-mesa0:i386 \
  libgl1-mesa-dri libgl1-mesa-dri:i386 \
  vulkan-tools

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

echo "==> steam (flatpak) + mangohud overlay for it"
flatpak install -y flathub com.valvesoftware.Steam
flatpak install -y flathub org.freedesktop.Platform.VulkanLayer.MangoHud//24.08 || \
  echo "mangohud flatpak layer failed, steam still works, native mangohud is installed for native games"

echo "==> serein (native discord client, flatpak from the project's own repo)"
flatpak install --user -y https://viceverse-cz.github.io/Serein/flatpak/serein.flatpakref || \
  echo "serein flatpak install failed, grab it later from the serein github releases"

echo "==> thorium browser (from thorium's own apt repo)"
sudo wget --no-hsts -P /etc/apt/sources.list.d/ https://dl.thorium.rocks/debian/dists/stable/thorium.list
sudo apt update
sudo apt install -y thorium-browser

echo "==> chatgpt (official .deb) + codex cli (.deb hosted on your forky-post-install repo)"
# chatgpt desktop app for linux is official now (preview): this is openai's own .deb, it also sets up their signed repo for updates
# their support list names debian 13; forky is testing (future 14), should work but is not formally listed
# codex: openai ships no .deb for the standalone cli; this deb wraps their official 0.166.0 linux binary from the openai/codex github release
wget -O /tmp/chatgpt_amd64.deb https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb
wget -O /tmp/openai-codex.deb https://github.com/cyroz1/forky-post-install/releases/latest/download/openai-codex_0.166.0_amd64.deb
sudo apt install -y /tmp/chatgpt_amd64.deb /tmp/openai-codex.deb

# ---------------------------------------------------------------------------
# clock fight fix (windows uses local time, linux defaults to utc)
# pick ONE side only. the install guide had you do the windows registry fix.
# if you did that, leave this commented out. if you did NOT, uncomment:
#
# timedatectl set-local-rtc 1
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# optional: LACT, amd gpu control panel (fan curves, clocks, power limit)
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

echo
echo "done. reboot, then check the gpu stack with:  vulkaninfo --summary | grep -A2 deviceName"
echo "in steam: set launch options per game to  mangohud gamemoderun %command%  (flatpak steam: mangohud works via the vulkan layer)"
