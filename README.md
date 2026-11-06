# forky-post-install

Post-install setup script for a Debian Forky (testing) dual boot on a
Ryzen 7 7800X3D / RX 7900 GRE rig: AMD graphics stack, Steam (Flatpak),
GameMode, MangoHud, OBS Studio, Thorium and Serein. ChatGPT and Codex
are installed separately after verifying their packages.

Also runs on arm64: the script detects the architecture and branches
where it matters. On arm64 it skips the x86-only pieces (i386 libs,
Steam and Thorium).

Install (pinned to the v2 release tag, checksum verified before anything runs):

```sh
curl -fsSL https://raw.githubusercontent.com/cyroz1/forky-post-install/v2/forky-post-install.sh -o forky-post-install.sh
echo "7f516be766a473e79b4ea01c023296d1cb0de6e8fca4d9c57a8ca3aa75740cf0  forky-post-install.sh" | sha256sum -c -
bash forky-post-install.sh
```

Piping the script straight into bash (`curl ... | bash`) also works: it
re-downloads itself from the same pinned tag and refuses to run if its
checksum does not match the one committed in the repo as
`forky-post-install.sh.sha256`.

Complete the Debian release upgrade to Forky before running the script. Review
its package removals and service changes before use. The script leaves existing
network management in place and does not install unverified standalone packages.

Thorium's upstream APT repository is unsigned (no signed Release, no
published key), so the script does not add it at all: it installs one
pinned Thorium .deb after verifying its SHA256, and removes the old
`thorium.list` source left behind by earlier versions. The script also
verifies that the system Flathub remote really points at
dl.flathub.org before installing from it, and checks the Serein
.flatpakref against pinned expectations before Flatpak adopts it.
