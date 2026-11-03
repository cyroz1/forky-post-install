# forky-post-install

Post-install setup script for a Debian Forky (testing) dual boot on a
Ryzen 7 7800X3D / RX 7900 GRE rig: AMD graphics stack, Steam (Flatpak),
GameMode, MangoHud, OBS Studio, Thorium, Serein, the official ChatGPT
.deb, plus an OpenAI Codex .deb hosted in this repo's releases.

Also runs on arm64: the script detects the architecture and branches
where it matters. On arm64 it skips the x86-only pieces (i386 libs,
Steam, Thorium, replaced with Chromium), installs the arm64 ChatGPT
.deb, and installs Codex from OpenAI's official aarch64 tarball.

One liner:

```sh
curl -fsSL https://raw.githubusercontent.com/cyroz1/forky-post-install/main/forky-post-install.sh | bash
```
