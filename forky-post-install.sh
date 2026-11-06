#!/usr/bin/env bash
# post-install setup for amir's debian forky dual boot
# main rig: ryzen 7 7800x3d, rx 7900 gre, gaming + dev (amd64)
# also runs on arm64 machines: arch-specific pieces branch below, and the
# handful of x86-only things (steam, thorium, 32-bit libs) skip cleanly
# instead of breaking the run.
# run AFTER first boot into debian:  chmod +x forky-post-install.sh && ./forky-post-install.sh
# Complete the Debian release upgrade to forky before running this script.
# Reboot when it finishes.

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
  # pinned to a release tag, never a moving branch: what runs here goes on
  # to sudo apt installs and root file writes, so the download is bound to
  # an immutable ref and verified against the checksum committed next to
  # it before anything executes. when cutting a new release: bump
  # SCRIPT_REF, regenerate forky-post-install.sh.sha256 with
  #   sha256sum forky-post-install.sh > forky-post-install.sh.sha256
  # commit both, then tag the release with the same name.
  SCRIPT_REF="v2"
  BOOTSTRAP_DIR="$(mktemp -d)"
  chmod 700 "$BOOTSTRAP_DIR"
  curl -fsSL "https://raw.githubusercontent.com/cyroz1/forky-post-install/$SCRIPT_REF/forky-post-install.sh" -o "$BOOTSTRAP_DIR/forky-post-install.sh"
  curl -fsSL "https://raw.githubusercontent.com/cyroz1/forky-post-install/$SCRIPT_REF/forky-post-install.sh.sha256" -o "$BOOTSTRAP_DIR/forky-post-install.sh.sha256"
  if ! (cd "$BOOTSTRAP_DIR" && sha256sum -c forky-post-install.sh.sha256); then
    echo "downloaded script failed its checksum check, refusing to run it" >&2
    exit 1
  fi
  # hand stdin back to the real terminal: the pipe is exhausted by now, and
  # leaving it attached makes tmux die with "open terminal failed"
  if [ -e /dev/tty ]; then
    exec bash "$BOOTSTRAP_DIR/forky-post-install.sh" "$@" </dev/tty
  fi
  exec bash "$BOOTSTRAP_DIR/forky-post-install.sh" "$@"
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
      printf -v TMUX_SCRIPT '%q' "$0"
      printf -v TMUX_ARGS ' %q' "$@"
      FORKY_SETUP_TMUX=1 exec tmux new-session -A -s forky-setup "bash $TMUX_SCRIPT$TMUX_ARGS; echo; echo '=== setup exited, press enter for a shell ==='; bash"
    fi
  fi
fi

echo "==> upgrade trixie to forky first, if this came from the stable image"
# the stable installer is the reliable way in; move the release up before
# installing anything so every package comes from forky
# Release upgrades require reviewing all sources and the proposed package changes.
# Never rewrite third-party sources or leave an unattended partial upgrade.
if find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec grep -El '(^|[[:space:]])trixie([[:space:]]|$)' {} + 2>/dev/null | grep -q .; then
  echo "Trixie sources detected. Complete the Debian release upgrade to forky manually, then rerun this script." >&2
  exit 1
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
# Leave existing network management and configuration in place. A safe
# handover requires confirming the active connection on the target machine.

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
# helpers: pull remote urls out of flatpak's detail listing
# ($1 = --system|--user, $2 = remote name for the single-remote form)
flatpak_remote_url() {
  flatpak remote-list -d "$1" 2>/dev/null | awk -v name="$2" '$1 == name { for (i = 1; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $i; exit } }'
}
flatpak_remote_urls() {
  flatpak remote-list -d "$1" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $i; break } }'
}
# the steam/mangohud installs below are --system, so the system remote is
# the one that has to be right. remote-add --if-not-exists alone would
# silently keep a pre-existing remote named flathub even if it pointed at
# a different repo with a different signing key. check the url, replace a
# wrong one, and refuse to go on if the system remote is not the real
# flathub afterwards.
FLATHUB_REMOTE_URL="https://dl.flathub.org/repo/"
system_flathub_url="$(flatpak_remote_url --system flathub)"
if [ -n "$system_flathub_url" ] && [ "$system_flathub_url" != "$FLATHUB_REMOTE_URL" ]; then
  echo "WARNING: the existing system flathub remote points at $system_flathub_url, replacing it with the real flathub" >&2
  sudo flatpak remote-delete --system flathub </dev/null || \
    echo "could not remove the wrong flathub remote, the check below will fail" >&2
  system_flathub_url=""
fi
if [ -z "$system_flathub_url" ]; then
  sudo flatpak remote-add --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo </dev/null
  system_flathub_url="$(flatpak_remote_url --system flathub)"
fi
if [ "$system_flathub_url" != "$FLATHUB_REMOTE_URL" ]; then
  echo "ERROR: system flathub remote is not $FLATHUB_REMOTE_URL, refusing to install flatpaks from it" >&2
  exit 1
fi

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
# a .flatpakref is a trust-root definition: it names the app, the remote
# to trust and the runtime repo, and flatpak adopts them persistently.
# pin what this one is allowed to declare, check the downloaded ref
# before flatpak sees it, and afterwards check which remotes the install
# actually added. a mismatch stops the run: silently accepting a
# different remote here hands a third-party site a permanent trusted
# install source. (the ref currently declares no GPGKey of its own; the
# remote it creates is bound by the url pin and the post-install check.)
SEREIN_REF_URL="https://viceverse-cz.github.io/Serein/flatpak/serein.flatpakref"
SEREIN_APP_ID="cz.viceverse.serein"
SEREIN_REMOTE_URL="https://viceverse-cz.github.io/Serein/flatpak/repo"
SEREIN_REF_FILE="$(mktemp)"
if ! curl -fsSL "$SEREIN_REF_URL" </dev/null | tr -d '\r' > "$SEREIN_REF_FILE"; then
  echo "serein flatpakref download failed, skipping serein" >&2
else
  for serein_expected in \
    "Name=$SEREIN_APP_ID" \
    "Url=$SEREIN_REMOTE_URL" \
    "Branch=master" \
    "RuntimeRepo=https://flathub.org/repo/flathub.flatpakrepo"; do
    if ! grep -qxF "$serein_expected" "$SEREIN_REF_FILE"; then
      echo "ERROR: serein.flatpakref does not match the pinned expectation: $serein_expected" >&2
      echo "refusing to install it; if serein moved, update the pins in this script" >&2
      rm -f "$SEREIN_REF_FILE"
      exit 1
    fi
  done
  serein_before="$(flatpak_remote_urls --user)"
  if flatpak install --user -y "$SEREIN_REF_FILE" </dev/null; then
    serein_after="$(flatpak_remote_urls --user)"
    serein_new="$(printf '%s\n' "$serein_after" | grep -Fxv -f <(printf '%s\n' "$serein_before") || true)"
    while IFS= read -r serein_new_url; do
      case "$serein_new_url" in
        ""|"$SEREIN_REMOTE_URL"|https://dl.flathub.org/repo/) ;;
        *)
          echo "ERROR: serein install added an unexpected user flatpak remote: $serein_new_url" >&2
          rm -f "$SEREIN_REF_FILE"
          exit 1
          ;;
      esac
    done <<< "$serein_new"
  else
    echo "serein flatpak install failed, grab it later from the serein github releases"
  fi
fi
rm -f "$SEREIN_REF_FILE"

if [ "$ARCH" = "amd64" ]; then
  echo "==> installing Thorium (pinned .deb, checksum verified)"
  # upstream's APT repository is unsigned: no signed Release and no
  # published key anywhere, so there is nothing for a signed-by keyring
  # to verify against, and the old setup's answer (a persistent
  # trusted=yes source) let that origin feed root installs forever.
  # instead: no repository at all. one pinned .deb, checked against the
  # sha256 below before apt sees it, and the legacy source file from
  # older runs removed. bump the url and sha256 together when updating
  # the pin (hashes are listed in the repo's own Packages index at
  # dists/stable/main/binary-amd64/Packages).
  THORIUM_DEB_URL="https://dl.thorium.rocks/debian/dists/stable/main/binary-amd64/thorium-browser_138.0.7204.303-1_amd64.deb"
  THORIUM_DEB_SHA256="9bfad87fd5119720a1bc47af3b3e3efcbd92910032aa949d97bdc5191e2edb60"
  sudo rm -f /etc/apt/sources.list.d/thorium.list
  THORIUM_DIR="$(mktemp -d)"
  chmod 755 "$THORIUM_DIR"
  if curl -fsSL "$THORIUM_DEB_URL" -o "$THORIUM_DIR/thorium.deb" </dev/null \
    && printf '%s  %s\n' "$THORIUM_DEB_SHA256" "$THORIUM_DIR/thorium.deb" | sha256sum -c - >/dev/null; then
    sudo apt install -y "$THORIUM_DIR/thorium.deb" || echo "thorium .deb install failed, skipping"
  else
    echo "thorium download or checksum check failed, skipping it (the pin above may need a bump)" >&2
  fi
  rm -rf "$THORIUM_DIR"
else
  echo "==> skipping Thorium on $ARCH: upstream only ships amd64 builds"
fi

echo "==> ChatGPT and Codex: install separately after verifying official packages"
echo "    Automatic installation is skipped because this script does not have trusted package signatures or pinned checksums."

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
