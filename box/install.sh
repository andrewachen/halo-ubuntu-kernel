#!/usr/bin/env bash
# install.sh — one-time consumer installer: point a fresh Ubuntu machine at the
# halo-ubuntu-kernel flat apt repo and install the halo kernel for a series.
# Run as root on the target machine. Machine safety is structural: the fetched
# signing key must be EXACTLY the published key (strict fingerprint identity,
# no extra keys) before the apt source is enabled, and the installation is
# SIMULATED first — an apt-get -s that would remove a firmware, microcode, or
# unexpected kernel package aborts before any real change. Firmware is marked
# manual before install; afterwards a persistent dpkg post-invoke hook
# re-marks every installed kernel image and modules package as manual, so
# autoremove can never strand firmware or a fallback kernel across future
# upgrades. The stock metas are removed by the install itself (expected); any
# stock metas still installed are held, dpkg-query derived, nothing hardcoded.
# A same-ABI stock respin can never win: release origin o=Ubuntu is downpinned
# to 100 while our flat repo (Origin: halo-ubuntu-kernel) stays at 500.
#
# usage: install.sh --series <noble|resolute> [--base URL]
#   --series NAME  noble or resolute (required; no default assumed)
#   --base URL     flat-repo base URL, defaulting to
#                  https://github.com/andrewachen/halo-ubuntu-kernel/releases/download/apt-<series>
#                  (override only for testing)
set -euo pipefail

KEYRING=/usr/share/keyrings/halo-ubuntu-kernel.gpg
SOURCE_LIST=/etc/apt/sources.list.d/halo-ubuntu-kernel.list
PIN_FILE=/etc/apt/preferences.d/halo-ubuntu-kernel
# The three fingerprints of the published signing key — public data, mirroring
# keys/repo-public-key.asc exactly: the primary key, its cv25519 ENCRYPTION
# subkey and the ed25519 SIGNING subkey. apt's signed-by trusts every usable
# signing key in a keyring, so the keyring must be EXACTLY these three records
# and nothing else — a compromised release asset shipping our key plus an
# attacker's would pass a mere presence check.
KEY_PRIMARY=9ADF54E73FF6D52E6165A4F6397268D545C7794B
KEY_ENC=02A42D21EB511FB51D380F65B888D02E6D1282D7
KEY_SIGN=65ED20E95E7D7DDAD55F76C390DFA288EBF76411

# usage is a literal, not `sed "$0"`: the README's curl | bash -s -- form
# runs this script from stdin, where $0 is "bash" and the header block is
# not on disk. Keep this text in sync with the header block above.
usage() {
  cat >&2 <<'USG'
install.sh — one-time consumer installer: point a fresh Ubuntu machine at the
halo-ubuntu-kernel flat apt repo and install the halo kernel for a series.
Run as root on the target machine. Machine safety is structural: the fetched
signing key must be EXACTLY the published key (strict fingerprint identity,
no extra keys) before the apt source is enabled, and the installation is
SIMULATED first — an apt-get -s that would remove a firmware, microcode, or
unexpected kernel package aborts before any real change. Firmware is marked
manual before install; afterwards a persistent dpkg post-invoke hook
re-marks every installed kernel image and modules package as manual, so
autoremove can never strand firmware or a fallback kernel across future
upgrades. The stock metas are removed by the install itself (expected); any
stock metas still installed are held, dpkg-query derived, nothing hardcoded.
A same-ABI stock respin can never win: release origin o=Ubuntu is downpinned
to 100 while our flat repo (Origin: halo-ubuntu-kernel) stays at 500.

usage: install.sh --series <noble|resolute> [--base URL]
  --series NAME  noble or resolute (required; no default assumed)
  --base URL     flat-repo base URL, defaulting to
                 https://github.com/andrewachen/halo-ubuntu-kernel/releases/download/apt-<series>
                 (override only for testing)
USG
}
die() { echo "install.sh: $*" >&2; exit 1; }

check_simulation() {  # <abi> — the ABI of the halo build being installed
  # Gate for the REAL install: read the full 'apt-get -s install ...' output on
  # stdin and return 0 only when every removal line is an EXPECTED removal.
  # Real apt-get -s prints removals as 'Remv linux-firmware [<ver>]' and
  # config-file purges as 'Purg <pkg> [<ver>]' — space, not 'Remv:'. Expected:
  # no firmware/microcode removal (the install removes the stock metas, so
  # linux-firmware could strand as autoremovable and the next autoremove would
  # kill amdgpu firmware), and no kernel image/modules removal except the
  # same-ABI stock packages our build replaces (the signed image and modules
  # of <abi>) plus the stock metas that depend on them — their removal is
  # documented as expected. Any other kernel removal — an other-ABI fallback
  # kernel above all — reprints the full output and returns 1, before any
  # real change has been made.
  local abi="$1" line verb pkg warn=0 warn_list='' sim=''
  while IFS= read -r line; do
    sim+="$line"$'\n'
    verb=${line%% *}          # 'Remv' | 'Purg' | 'Inst' | 'Conf' | ...
    case "$verb" in
      Remv|Purg)
        pkg=${line#* }        # drop the verb
        pkg=${pkg%% *}        # the package name only, never the [version]
        case "$pkg" in
          *firmware*|*microcode*) warn=1; warn_list="$warn_list $pkg" ;;
          # expected removals: the same-ABI stock signed image and stock
          # modules our build replaces, and the stock metas that select them
          "linux-image-$abi-generic" \
            | "linux-modules-$abi-generic" | "linux-modules-extra-$abi-generic" \
            | linux-image-generic* | linux-generic*) ;;
          # any other kernel image/modules removal — an other-ABI fallback
          # kernel above all — must abort
          linux-image-*|linux-modules-*) warn=1; warn_list="$warn_list $pkg" ;;
        esac
        ;;
    esac
  done
  [ "$warn" -eq 0 ] || {
    echo "install.sh: the simulation would REMOVE a protected package:${warn_list} — refusing to proceed:" >&2
    echo "--- full simulated output ---" >&2
    printf '%s' "$sim" >&2
    echo "------------------------------" >&2
    return 1
  }
  return 0
}

verify_key() {  # <keyring-file> — the keyring must be EXACTLY the published key
  # apt's signed-by trusts every usable signing key in a keyring, so "our
  # fingerprint is present" is not enough — a compromised release asset could
  # ship our key plus an attacker's. Fail unless the keyring holds exactly one
  # key block whose fingerprint set is exactly the KEY_* constants above
  # (mirroring the committed keys/repo-public-key.asc).
  local file="$1" out npub nfpr fprs
  out=$(gpg --show-keys --with-colons "$file" 2>/dev/null) || return 1
  read -r npub nfpr <<< "$(printf '%s\n' "$out" \
    | awk -F: '/^pub:/ {p++} /^fpr:/ {f++} END {print p+0, f+0}')"
  [ "$npub" -eq 1 ] || return 1
  [ "$nfpr" -eq 3 ] || return 1
  fprs=$(printf '%s\n' "$out" | awk -F: '/^fpr:/ {print $10}')
  for want in "$KEY_PRIMARY" "$KEY_ENC" "$KEY_SIGN"; do
    printf '%s\n' "$fprs" | grep -Fqx "$want" || return 1
  done
  return 0
}

is_installed_status() {  # <db:Status-Abbrev> — 0 when the package is install ok installed
  # db:Status-Abbrev is FIXED-WIDTH 3 chars: an installed package reads 'ii '
  # (the trailing space is the empty error field), so an exact 'ii' comparison
  # rejects EVERY installed package. Compare the space-stripped abbreviation.
  local abbr
  abbr=$(printf '%s' "$1" | tr -d ' ')
  [ "$abbr" = ii ]
}

select_installed() {  # stdin: '<db:Status-Abbrev>\t<Package>' lines — print installed names
  awk -F'\t' '$1 ~ /^ii ?$/ {print $2}'
}

mark_manual() {
  # apt-mark manual each package named on stdin, but only when it is actually
  # INSTALLED (is_installed_status on db:Status-Abbrev). dpkg-query -s exits 0
  # for rc (config-files) packages too, which would apt-mark a package that is
  # not installed — filter on install ok installed instead. Once the stock
  # metas are gone, an unmarked linux-firmware can be swept by autoremove; the
  # manual marks make "never autoremoved" true for firmware and kernel images
  # alike.
  local pkg status
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    status=$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null) || status=''
    is_installed_status "$status" || continue
    echo "install.sh: marking $pkg manual (never autoremoved)" >&2
    apt-mark manual "$pkg" || die "apt-mark manual $pkg failed"
  done
}

hold_stock_metas() {
  # Hold every INSTALLED stock meta in place, derived from dpkg-query so the
  # exact names — including future -hwe-<series> suffixes — are covered with
  # nothing hardcoded. Only install ok installed (ii) packages are held (the
  # db:Status-Abbrev field is fixed-width, hence select_installed's shape): a
  # long-gone meta left as config-files (rc) must never be apt-mark'd. A glob
  # matching nothing is fine (that series has no such meta) — the loop body
  # never runs.
  local pkg
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    echo "install.sh: holding stock meta $pkg" >&2
    apt-mark hold "$pkg" || die "apt-mark hold $pkg failed"
  done < <({ dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' \
              'linux-generic*' 'linux-image-generic*' 'linux-headers-generic*' 2>/dev/null || true; } \
          | select_installed)
}

main() {
  local series='' base='' abi=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --series) [ $# -ge 2 ] || { echo "install.sh: --series needs a name" >&2; usage; exit 2; }
                series="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || { echo "install.sh: --base needs a URL" >&2; usage; exit 2; }
              base="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) echo "install.sh: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
  done
  [ -n "$series" ] || { echo "install.sh: --series is required (noble or resolute)" >&2; usage; exit 2; }
  case "$series" in
    noble|resolute) ;;
    *) echo "install.sh: unknown series '$series' (expected noble or resolute)" >&2; exit 1 ;;
  esac
  [ "$(id -u)" -eq 0 ] || die "must run as root — this installer configures apt and installs kernels"
  command -v curl >/dev/null 2>&1 || die "curl is required but not installed (install it with: apt-get install -y curl)"
  command -v gpg >/dev/null 2>&1 || die "gpg is required but not installed (install it with: apt-get install -y gnupg)"
  if [ -z "$base" ]; then
    base="https://github.com/andrewachen/halo-ubuntu-kernel/releases/download/apt-$series"
  fi

  tmp=$(mktemp -d) || die "mktemp -d failed"
  trap 'rm -rf "$tmp"' EXIT

  mkdir -p /usr/share/keyrings
  echo "install.sh: fetching the repo signing key from $base ..." >&2
  # dearmor to a TEMP path first: the live keyring is only replaced after the
  # fetched key passes the strict identity check, so a bad fetch on a re-run can
  # never overwrite the trusted key while the source stays enabled.
  curl -fsSL "$base/repo-public-key.asc" | gpg --dearmor --yes -o "$tmp/key.gpg" \
    || die "failed to fetch/decode $base/repo-public-key.asc"
  echo "install.sh: verifying the fetched key is EXACTLY the published halo key ..." >&2
  if ! verify_key "$tmp/key.gpg"; then
    die "fetched key is not exactly the published key — expected one block with the three KEY_* fingerprints; aborting before any apt source is enabled"
  fi
  install -m 0644 "$tmp/key.gpg" "$KEYRING.tmp" || die "cannot stage the verified keyring"
  mv -f "$KEYRING.tmp" "$KEYRING" || die "cannot install the verified keyring"

  mkdir -p /etc/apt/sources.list.d
  echo "install.sh: enabling the apt source (key verified): deb [signed-by=$KEYRING] $base/ /" >&2
  # OBS-style flat source line, ending in the bare ' /' suite. The './' form
  # made apt request '<base>//InRelease', unproven on GitHub's router — the
  # bare suite is the verified form.
  printf 'deb [signed-by=%s] %s/ /\n' "$KEYRING" "$base" > "$SOURCE_LIST"

  echo "install.sh: apt-get update ..." >&2
  if ! apt-get update; then
    rm -f "$SOURCE_LIST"
    die "apt-get update failed — the just-enabled source was removed again; nothing has been installed"
  fi
  echo "install.sh: simulating 'apt-get install linux-image-halo-$series' before changing anything ..." >&2
  if ! apt-get -s install "linux-image-halo-$series" >"$tmp/sim" 2>&1; then
    cat "$tmp/sim" >&2
    die "apt-get -s install failed — see the simulated output above"
  fi
  # The ABI of the build the simulation selected. The removal gate allows
  # exactly the same-ABI stock packages our image replaces, so the ABI must
  # come from the simulation itself, never from an argument or an assumption.
  abi=$(sed -n 's/^Inst linux-image-unsigned-\([^ ]*\)-generic .*/\1/p' "$tmp/sim" | head -1)
  [ -n "$abi" ] || {
    cat "$tmp/sim" >&2
    die "the simulation did not select linux-image-unsigned-<abi>-generic — cannot gate removals"
  }
  if ! check_simulation "$abi" < "$tmp/sim"; then
    die "refusing to install: the simulation removes a protected package — see the full simulated output above; nothing was changed"
  fi

  # firmware first, so a partial failure after the metas are removed can never
  # leave linux-firmware unmarked and autoremovable (a re-run finishes the rest)
  echo "install.sh: marking firmware/microcode manual BEFORE install ..." >&2
  printf '%s\n' linux-firmware amd64-microcode intel-microcode | mark_manual \
    || die "apt-mark manual failed"

  echo "install.sh: installing linux-image-halo-$series ..." >&2
  # both frontends must be non-interactive, not cosmetic: in the README's
  # curl | bash -s -- form the script's stdin is the drained curl pipe, so
  # an apt [Y/n] prompt reads EOF and aborts mid-install — and removing the
  # same-ABI stock kernel makes its prerm ask "Abort kernel removal?" via
  # linux-check-removal, which -y alone does not silence. The simulation
  # gate above guards safety.
  DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-image-halo-$series" \
    || die "apt-get install linux-image-halo-$series failed"

  echo "install.sh: marking installed kernel images manual ..." >&2
  # 'linux-image-*[0-9]*-generic' covers BOTH image name shapes — the stock
  # signed linux-image-<abi>-generic and our linux-image-unsigned-<abi>-generic
  # (the old 'linux-image-[0-9]*' glob missed the unsigned form, so our own
  # image was never marked). The [0-9]*-generic tail keeps the meta packages
  # (linux-image-generic*) out: metas are held, not marked.
  { dpkg-query -W -f='${Package}\n' 'linux-image-*[0-9]*-generic' 2>/dev/null || true; } \
    | mark_manual || die "apt-mark manual failed"

  echo "install.sh: holding the installed stock metas ..." >&2
  hold_stock_metas

  mkdir -p /etc/apt/preferences.d
  echo "install.sh: writing the apt pin (stock release origin o=Ubuntu linux-image*/linux-modules* down to 100) ..." >&2
  cat > "$PIN_FILE" <<EOF
Package: linux-image* linux-modules*
Pin: release o=Ubuntu
Pin-Priority: 100
EOF

  echo "install.sh: installing the persistent kernel-protection hook ..." >&2
  mkdir -p /usr/lib/halo-ubuntu-kernel /etc/apt/apt.conf.d
  # Persistent protection for FUTURE upgrades: after every apt/dpkg run, re-mark
  # every installed kernel image and modules package as manual, so autoremove
  # can never sweep a fallback kernel away when a later meta upgrade drops the
  # old image from its dependency chain. Mirrors update-notifier's
  # 01autoremove-kernels mechanism (a DPkg::Post-Invoke guard script).
  cat > /usr/lib/halo-ubuntu-kernel/keep-kernels <<'EOF'
#!/bin/sh
# Installed by halo-ubuntu-kernel box/install.sh. After every apt/dpkg run,
# re-mark every installed kernel image and modules package as manually
# installed: fallback kernels must survive autoremove across future meta
# upgrades (mirrors update-notifier's 01autoremove-kernels guard).
pkgs=$(dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' \
         'linux-image-*[0-9]*-generic' 'linux-modules-*[0-9]*-generic' 2>/dev/null \
       | awk -F'\t' '$1 ~ /^ii ?$/ {print $2}')
[ -n "$pkgs" ] && apt-mark manual $pkgs >/dev/null 2>&1
# never fail the apt run that invoked us
exit 0
EOF
  chmod 0755 /usr/lib/halo-ubuntu-kernel/keep-kernels
  cat > /etc/apt/apt.conf.d/99-halo-keep-kernels <<'EOF'
// Installed by halo-ubuntu-kernel box/install.sh: after every apt/dpkg run,
// keep every installed kernel image and modules package marked manual so
// autoremove never removes a fallback kernel. See
// /usr/lib/halo-ubuntu-kernel/keep-kernels.
DPkg::Post-Invoke { "/usr/lib/halo-ubuntu-kernel/keep-kernels" };
EOF

  cat >&2 <<EOF
install.sh: DONE — linux-image-halo-$series installed from $base.

- Reboot manually whenever ready; 'uname -r' must show the halo kernel after boot.
- Within-ABI rollback (same ABI, older build): 'sudo apt install <pkg>=<oldEVR> --allow-downgrades'
- Other-ABI kernels you had installed survive as GRUB fallbacks. The stock metas
  were removed by this install (expected). Future autoremoves can never touch
  linux-firmware, the microcode packages or any installed kernel: the
  post-invoke hook (/etc/apt/apt.conf.d/99-halo-keep-kernels) re-marks every
  installed kernel image and modules package manual after every apt run.
EOF
}

# run main when executed as a file (BASH_SOURCE[0] == $0) or piped into
# bash via the README's curl | sudo bash -s -- form, where the script comes
# from stdin and BASH_SOURCE is unset entirely; skip only when sourced
# (BASH_SOURCE[0] set and different from $0)
if [ ! -v BASH_SOURCE ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
