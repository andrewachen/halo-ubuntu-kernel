#!/usr/bin/env bash
# build-meta-deb.sh — build the control-only meta package linux-image-halo-<series>
# for one series, versioned with the exact EVR of the halo kernel it pulls in.
# Installing it installs the exact linux-image-unsigned-<abi>-generic and
# linux-modules-<abi>-generic (both pinned = EVR) plus the split modules the
# stock meta depends on (SPLIT_MODULES in series/<series>/series.env — Ubuntu
# no longer ships modules-extra; the splits are Ubuntu's own debs pinned at
# the STOCK EVR, our +halokN suffix stripped: same source version and ABI as
# our rebuild, so they are vermagic/CRC-compatible) plus linux-firmware and
# amd64-microcode. The modules pin forces our own modules deb in — a stock
# same-ABI modules package would otherwise satisfy the image's unversioned
# dependency. The firmware deps ride the meta because installing our image
# removes the stock metas (the signed-image Conflicts chain) that previously
# guaranteed them. No postinst/postrm — apt handles it.
#
# usage: build-meta-deb.sh --series NAME --evr EVR [--output DIR]
#                          [--print-control]
#   --series NAME       noble or resolute (reads series/<NAME>/series.env for
#                       SPLIT_MODULES)
#   --evr EVR           exact version the meta carries and pins (no whitespace,
#                       at least one digit — a malformed EVR is a usage error)
#   --output DIR        where the deb lands (default: $PWD/output); created if
#                       missing; refusing to overwrite an existing deb
#   --print-control     print the generated control file to stdout and exit;
#                       no side effects — nothing is created
set -u

usage() { sed -n '2,24p' "$0" >&2; }
die() { echo "build-meta-deb: $*" >&2; exit 1; }

series='' evr='' output='' print_control=0
while [ $# -gt 0 ]; do
  case "$1" in
    --series) series="$2"; shift 2 ;;
    --evr) evr="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --print-control) print_control=1; shift ;;
    *) echo "build-meta-deb: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$series" ] || { echo "build-meta-deb: --series is required" >&2; usage; exit 2; }
[ -n "$evr" ] || { echo "build-meta-deb: --evr is required" >&2; usage; exit 2; }

case "$series" in
  noble|resolute) ;;
  *) echo "build-meta-deb: unknown series '$series' (expected noble or resolute)" >&2; exit 1 ;;
esac

# EVR shape gate, before the ABI derivation (which keys off the first '-'):
# <upstream>-<revision>[.<rest>] with leading digits, no epoch ':', no '/', no
# whitespace anywhere. Anything else is a usage error — the derivation would be
# unsound for it (e.g. an epoch or a missing revision).
case "$evr" in
  *[[:space:]]*) echo "build-meta-deb: --evr '$evr' contains whitespace" >&2; usage; exit 2 ;;
  *:*) echo "build-meta-deb: --evr '$evr' has an epoch (':' is not allowed)" >&2; usage; exit 2 ;;
esac
if ! printf '%s\n' "$evr" | grep -Eq '^[0-9][0-9.]*-[0-9]+(\.[^[:space:]/:]*)?$'; then
  echo "build-meta-deb: --evr '$evr' must be <upstream>-<revision>[.<rest>] (leading digits/'.', revision with leading digits, no ':' '/' or whitespace)" >&2
  usage; exit 2
fi

kernel_abi_of() {
  # Debian kernel ABI from the EVR: the upstream part before the first '-' joined
  # to the revision-major (the remainder's part before the first '.').
  # 7.0.0-38.38~24.04.4+halok1 -> 7.0.0-38; 7.0.0-39.39 -> 7.0.0-39.
  local upstream="${1%%-*}"
  local rest="${1#*-}"
  printf '%s-%s\n' "$upstream" "${rest%%.*}"
}
abi=$(kernel_abi_of "$evr")

# The split modules are pinned at the STOCK EVR — our +halokN suffix is
# publish-local and the stock debs do not carry it. Same-source-version
# modules load fine against the rebuild (identical vermagic and symbol CRCs).
case "$evr" in
  *+halok*) stock_evr=${evr%+halok*} ;;
  *) stock_evr=$evr ;;
esac

# SPLIT_MODULES comes from the series definition (noble: zfs v4l2loopback,
# mirroring stock linux-image-generic-hwe-24.04; resolute: zfs, mirroring
# stock linux-image-generic). A missing series.env degrades to no split deps.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd) || die "cannot locate the script dir"
REPO=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd) || die "cannot locate the repo root"
split_deps=''
if [ -f "$REPO/series/$series/series.env" ]; then
  # shellcheck disable=SC1090 # series path is a runtime arg
  . "$REPO/series/$series/series.env"
  for m in ${SPLIT_MODULES:-}; do
    split_deps="$split_deps, linux-main-modules-$m-$abi-generic (= $stock_evr)"
  done
fi

control_file() {
  cat <<EOF
Package: linux-image-halo-$series
Version: $evr
Section: kernel
Priority: optional
Architecture: amd64
Maintainer: halo-ubuntu-kernel <andrewachen@users.noreply.github.com>
Depends: linux-image-unsigned-$abi-generic (= $evr), linux-modules-$abi-generic (= $evr)$split_deps, linux-firmware, amd64-microcode
Description: halo kernel and firmware meta package for $series
 Meta package pulling in the halo kernel build (AMD PerfOpt backport and Zen 5 build target) for this series.
EOF
}

if [ "$print_control" -eq 1 ]; then
  # Short-circuit: nothing beyond this point may run — no mkdir or mktemp.
  control_file
  exit 0
fi

output=${output:-$PWD/output}
target="$output/linux-image-halo-${series}_${evr}_amd64.deb"
[ -e "$target" ] && die "refusing to overwrite existing $target"

mkdir -p "$output" || die "cannot create output dir $output"
staging=$(mktemp -d) || die "mktemp -d failed"
# mktemp -d creates 0700, which dpkg-deb preserves as the data tarball's
# top-level './' entry — a package built from that dir would chmod its install
# target to 0700. Make the package root world-readable before building.
chmod 0755 "$staging" || die "chmod 0755 $staging failed"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/DEBIAN" || die "cannot create $staging/DEBIAN"
control_file > "$staging/DEBIAN/control" || die "cannot write $staging/DEBIAN/control"
# --root-owner-group so the package builds without fakeroot; dpkg-deb's own
# "building package" chatter goes to stdout, our record to stderr
dpkg-deb --build --root-owner-group "$staging" "$target" >/dev/null \
  || die "dpkg-deb --build failed"
echo "build-meta-deb: $(basename -- "$target") -> $output" >&2
