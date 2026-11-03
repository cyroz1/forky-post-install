# forky-post-install

Post-install setup script for a Debian Forky (testing) dual boot on a
Ryzen 7 7800X3D / RX 7900 GRE rig: AMD graphics stack, Steam (Flatpak),
GameMode, MangoHud, OBS Studio, Chromium and Serein. ChatGPT and Codex
are installed separately after verifying their packages.

Also runs on arm64: the script detects the architecture and branches
where it matters. On arm64 it skips the x86-only pieces (i386 libs,
Steam; Chromium is installed instead of Thorium).

One liner:

```sh
curl -fsSL https://raw.githubusercontent.com/cyroz1/forky-post-install/main/forky-post-install.sh | bash
```

Complete the Debian release upgrade to Forky before running the script. Review
its package removals and service changes before use. The script leaves existing
network management in place and does not install unverified standalone packages.
