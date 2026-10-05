# halo-ubuntu-kernel

A repo of scripts and GitHub Actions that rebuilds Ubuntu LTS kernels (24.04
noble, 26.04 resolute) from the stock Ubuntu source with two small changes for
AMD Halo-family APUs: the AMD PerfOpt IOMMU bypass, a feature queued for
mainline Linux 7.4 and backported here from the public upstream amd-gfx/iommu
patch series, plus a Zen 5 build target. GitHub Actions rebuilds and
republishes them as an apt repo on every Ubuntu ABI bump, so the author's
machines get kernel updates through plain `apt upgrade`.

## Should you use this?

Probably not. This is a one-person, unsigned kernel build for one family of
hardware, with no distro support. Read this before deciding.

Do use it if **all** of these are true:

- You run an AMD Halo-family APU (Strix Halo today, Gorgon Halo next) on
  Ubuntu 24.04 or 26.04.
- You are comfortable running an unsigned community kernel with no distro
  maintainer.
- You want the PerfOpt IOMMU bypass now, before your distro kernel carries it.

Do not use it if **any** of these is true:

- It is any other hardware. The kernel is compiled for Zen 5 and will not boot
  elsewhere.
- You need Secure Boot or signed kernels. These kernels are unsigned and will
  not boot with Secure Boot enabled; this is built for machines that run with
  Secure Boot off.
- You want distro-supported update channels. There are none here.

Even on an AMD Halo-family APU, the honest default is to wait: Linux 7.4 lands
this feature upstream, so for most people the right call is to let your distro
carry it. This repo exists because the author's machines should not wait.

## What's inside

- [box/install.sh](box/install.sh): one-time installer for a target machine.
- `scripts/`: upstream check, kernel build, flat apt index + publish, leak gate.
- `series/<series>/`: per-Ubuntu-series definitions. noble builds the
  `linux-hwe-7.0` source package; resolute builds plain `linux`.
- `patches/v7.0/`: the backport, from the public upstream amd-gfx/iommu
  series, adapted to the 7.0 kernel tree. Nothing vendor-internal enters this
  repo. The Zen 5 build target is not a patch: the build sets
  `KCFLAGS="-march=znver5 -mtune=znver5"`.
- [keys/repo-public-key.asc](keys/repo-public-key.asc): the public half of
  the dedicated apt-repo signing key. The installer fingerprint-verifies the
  fetched key against it before enabling the apt source.
- `.github/workflows/`: the build pipeline and CI. The whole apt repo is served
  from GitHub Release assets, one rolling `apt-<series>` Release per Ubuntu
  series, with no other hosting.

## How to use it

On a supported machine (AMD Halo-family APU, Ubuntu 24.04 or 26.04, root):

```
sudo box/install.sh --series noble      # or: --series resolute
```

The installer enables the apt source, verifies the signing key, and installs
the meta package `linux-image-halo-<series>`. After that, kernel updates are:

```
sudo apt update && sudo apt upgrade
```

Reboot when you choose, never automatically.

The apt source is an OBS-style flat line pointing at the `apt-<series>`
Release assets, for example:

```
deb [signed-by=/usr/share/keyrings/halo-ubuntu-kernel.gpg] https://github.com/andrewachen/halo-ubuntu-kernel/releases/download/apt-noble/ /
```

Rollback. Other-ABI stock kernels you had installed survive as GRUB
fallbacks: our `+halokN` kernel of a given ABI replaces the stock packages of
that ABI (same package names, a higher version), so only other ABIs are left
to boot. Boot one from the grub menu. Within an ABI, a plain install will not
downgrade; to go back to an older build of the same ABI, run:

```
sudo apt install <package>=<old version> --allow-downgrades
```

The install removes the stock kernel meta packages (our kernel conflicts with
the stock signed images, which pulls the metas off). That is expected. The
meta package depends on `linux-firmware` and `amd64-microcode` itself, so
firmware stays installed.

If you ever need the bypass off, pass `amdgpu.iommu_perfopt=0` on the kernel
command line.

Operations notes:

- GitHub auto-disables scheduled workflows in repos with no activity for 60
  days. The daily check job's status is this pipeline's health surface: a red
  or missing check means the next update will not arrive. Check it before
  rebooting a machine.
- Keep the running kernel plus two known-good fallbacks on disk and prune
  older kernels manually.

## How it works

A daily GitHub Actions run resolves the newest kernel ABI in the Ubuntu
archive for each series, compares it to the published apt index (the index,
not the releases, is the source of truth), and when the archive moved, builds
the Ubuntu source with our patches in a container, version-bumps it with a
`+halokN` changelog entry, and publishes the debs plus a signed flat index as
assets of the rolling `apt-<series>` Release. Every publish is validated
against a real apt client before the index goes live. See
[.github/workflows/build.yml](.github/workflows/build.yml).
