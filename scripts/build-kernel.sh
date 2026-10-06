#!/usr/bin/env bash
# build-kernel.sh — fetch the pinned Ubuntu source for a series, apply our patch
# series at --fuzz=0 (the authoritative patch gate), prepend the +halokN
# changelog entry, build the generic flavor only, and verify the payload.
#
# usage: build-kernel.sh --series NAME --upstream VERSION --n N
#                        [--output DIR] [--work-dir DIR] [--jobs N]
#                        [--print-plan] [--patch-only] [--patches-dir DIR]
#                        [--fake-source-tree DIR]
#   --print-plan        print the real-mode command sequence and exit; no side
#                       effects — nothing is created, fetched, or read
#   --patch-only        apply the patch series and stop — no build-dep, no
#                       debian/rules (the patch gate without the compile)
#   --patches-dir DIR   patch series dir (default: patches/<PATCHSET>)
#   --fake-source-tree DIR   patch DIR instead of fetched source; implies
#                       --patch-only (fixture mode; needs no --upstream/--n)
#   --output DIR        where collected debs land (default: $PWD/output)
#   --work-dir DIR      parent for the multi-GB build scratch (default: $TMPDIR
#                       or /tmp); the workflow passes /mnt/halo-build so the
#                       tree lands on the runner's scratch volume, not /
#   --jobs N            CONCURRENCY_LEVEL for the build (default: nproc)
#
# Real mode needs root (apt-get build-dep) and network; the CI build jobs run
# in containers as root. --patch-only and --print-plan need neither.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/version.sh
. "$REPO/scripts/lib/version.sh"
# shellcheck source=scripts/lib/selfcheck.sh
. "$REPO/scripts/lib/selfcheck.sh"
# shellcheck source=scripts/lib/apt-src.sh
. "$REPO/scripts/lib/apt-src.sh"
usage() { sed -n '2,24p' "$0" >&2; }
die() { echo "build-kernel: $*" >&2; exit 1; }

kcflags='-march=znver5 -mtune=znver5'
series='' upstream='' n='' output='' work_dir_arg='' jobs='' print_plan=0 patch_only=0 patches_dir='' fake_tree=''
while [ $# -gt 0 ]; do
  case "$1" in
    --series) series="$2"; shift 2 ;;
    --upstream) upstream="$2"; shift 2 ;;
    --n) n="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --work-dir) work_dir_arg="$2"; shift 2 ;;
    --jobs) jobs="$2"; shift 2 ;;
    --print-plan) print_plan=1; shift ;;
    --patch-only) patch_only=1; shift ;;
    --patches-dir) patches_dir="$2"; shift 2 ;;
    --fake-source-tree) fake_tree="$2"; shift 2 ;;
    *) echo "build-kernel: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$series" ] || { echo "build-kernel: --series is required" >&2; usage; exit 2; }
# shellcheck disable=SC1090 # series path is a runtime arg, not resolvable statically
. "$REPO/series/$series/series.env" || {
  echo "build-kernel: no series definition at series/$series/series.env" >&2; exit 1
}

# a version is needed for everything except patching a fake source tree
if [ -z "$upstream" ] || [ -z "$n" ]; then
  if [ -z "$fake_tree" ] || [ "$print_plan" -eq 1 ]; then
    echo "build-kernel: --upstream and --n are required" >&2; usage; exit 2
  fi
fi
# a series.env without the variable must not abort under set -u
COMPILER_OVERRIDE=${COMPILER_OVERRIDE-}
our_version=''
[ -z "$upstream" ] || our_version=$(append_halo_suffix "$upstream" "$n")
output=${output:-$PWD/output}
# the build scratch is multi-GB: default off the root fs, and the workflow
# pins it to the runner's scratch volume via --work-dir
work_dir=${work_dir_arg:-${TMPDIR:-/tmp}}
# shellcheck disable=SC2016 # $TMPDIR is printed literally in the plan
if [ -n "$work_dir_arg" ]; then work_dir_src='--work-dir'
elif [ -n "${TMPDIR-}" ]; then work_dir_src='$TMPDIR'
else work_dir_src='default (/tmp)'; fi
jobs=${jobs:-$(nproc)}
patches_dir=${patches_dir:-$REPO/patches/$PATCHSET}

if [ "$print_plan" -eq 1 ]; then
  # Short-circuit: nothing beyond this point may run — no mkdir, mktemp, or
  # helper call. DEBIAN is printed as the deferred lookup real mode performs,
  # never resolved here (the tree does not exist yet).
  gcc_arg=''
  [ -z "$COMPILER_OVERRIDE" ] || gcc_arg=" gcc=$COMPILER_OVERRIDE"
  if [ -n "$COMPILER_OVERRIDE" ]; then gcc_expect="$COMPILER_OVERRIDE"; else
    gcc_expect="the packaging's native gcc"; fi
  cat <<EOF
# build plan for $series: $SOURCE_PKG $upstream -> $our_version
work-dir: $work_dir (from $work_dir_src)
apt-get source --download-only "$SOURCE_PKG=$upstream"   # pinned; isolated deb-src state dirs
dpkg-source -x <downloaded .dsc> <tree>
QUILT_PATCHES=$patches_dir quilt --quiltrc=- push -a --fuzz=0   # hard-fails on any fuzz
DEBIAN=\$(sed -n "s/^DEBIAN=//p" <tree>/debian/debian.env)
printf '%s ($our_version) $series; urgency=medium\n\n  * AMD PerfOpt IOMMU backport + Zen 5 build target.\n\n -- halo-ubuntu-kernel <kernel@localhost>  %s\n\n' "$SOURCE_PKG" "\$(date -R)" > <tree>/\$DEBIAN/changelog.new
cat <tree>/\$DEBIAN/changelog >> <tree>/\$DEBIAN/changelog.new && mv <tree>/\$DEBIAN/changelog.new <tree>/\$DEBIAN/changelog
dpkg-parsechangelog -l <tree>/\$DEBIAN/changelog -S Version   # must equal $our_version before compiling
apt-get build-dep -y <downloaded .dsc>
# the debian/rules invocations below are wrapped in fakeroot ONLY when the
# caller is non-root (fakeroot's per-file-op IPC serializes the build ~10x;
# as root the debs record real uid 0 anyway)
PATH="/usr/lib/ccache:\$PATH" CCACHE_DIR=$output/ccache CCACHE_MAXSIZE=5G debian/rules clean
# annotation pre-flight: probe the packaging's prepare target (config export,
# olddefconfig, annotations --check); on CONFIG_CC_HAS_* -> y drift only
# (compiler-capability probes), repair via the packaging's annotations
# --write and re-run; any other drift hard-fails before the ~3h compile
PATH="/usr/lib/ccache:\$PATH" CCACHE_DIR=$output/ccache CCACHE_MAXSIZE=5G debian/rules prepare-generic$gcc_arg
PATH="/usr/lib/ccache:\$PATH" CCACHE_DIR=$output/ccache CCACHE_MAXSIZE=5G CONCURRENCY_LEVEL=$jobs KCFLAGS='$kcflags' skipabi=true skipdbg=true debian/rules binary-generic$gcc_arg
collect linux-image-unsigned-* + linux-modules-* debs from <tree>/.. into $output/debs; known by-products (linux-headers-*/linux-buildinfo-*/linux-tools*/linux-cloud-tools*/linux-libc-dev*/linux-lib-rust-*/linux-bpf-dev*/linux-main-modules-*, any .ddeb) are ignored with a warning; any other unexpected .deb = fail
assert: image deb version ends +halok$n; modules deb contains path-anchored mlx5_core.ko mlx5_ib.ko fwctl.ko mlx5_fwctl.ko; CONFIG_GCC_VERSION matches $gcc_expect; a .cmd file contains -march=znver5; ccache --print-stats recorded (zero hits = warning)
EOF
  exit 0
fi

# --- the patch gate ---------------------------------------------------------
[ -f "$patches_dir/series" ] || die "no series file in $patches_dir"
patches_dir=$(CDPATH='' cd -- "$patches_dir" && pwd) || die "patches dir not readable: $patches_dir"

[ -n "$fake_tree" ] && patch_only=1   # --fake-source-tree implies --patch-only

# the build scratch is multi-GB: it must land on the work dir (the workflow's
# scratch volume), never on the container's root fs
mkdir -p "$work_dir" || die "cannot create work dir $work_dir"
scratch=$(mktemp -d "$work_dir/halo-build.XXXXXX") || die "mktemp -d failed under $work_dir"
keep_tree=0
cleanup() { [ "$keep_tree" -eq 1 ] || rm -rf "$scratch"; }
trap cleanup EXIT

if [ -n "$fake_tree" ]; then
  tree=$scratch/tree
  mkdir "$tree" || die "mkdir $tree failed"
  cp -a "$fake_tree/." "$tree/" || die "cannot copy $fake_tree into $tree"
else
  # Pinned fetch: exactly the version the check decided on, so the check's
  # decision and the build input cannot diverge. Same isolated deb-src state
  # as the apt-src helper; no root needed for this step.
  # shellcheck disable=SC2153 # SERIES comes from the sourced series.env
  apt_src_update "$SERIES" "$scratch" || die "apt-get update failed for series $SERIES"
  ( cd "$scratch" && apt_src_download "$SERIES" "$scratch" "$SOURCE_PKG=$upstream" ) \
    || die "apt-get source --download-only $SOURCE_PKG=$upstream failed"
  set -- "$scratch"/*.dsc
  if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    die "expected exactly one .dsc in $scratch"
  fi
  tree=$scratch/src
  dpkg-source -x "$1" "$tree" || die "dpkg-source -x failed"
fi

# --quiltrc=- keeps the gate hermetic: no ~/.quiltrc overrides can weaken it
if ! ( cd "$tree" && QUILT_PATCHES="$patches_dir" QUILT_PC="$tree/.pc" \
         quilt --quiltrc=- push -a --fuzz=0 ); then
  # keep the tree: the rejects and .pc state are the debugging artifact
  keep_tree=1
  die "patch series failed to apply at --fuzz=0 (tree kept for inspection: $tree)"
fi

if [ "$patch_only" -eq 1 ]; then
  echo "build-kernel: patch-only: series applied cleanly at --fuzz=0 in $tree" >&2
  exit 0
fi

# --- real mode: changelog bump, then binary-generic --------------------------
DEBIAN=$(sed -n "s/^DEBIAN=//p" "$tree/debian/debian.env")
[ -n "$DEBIAN" ] || die "debian/debian.env does not set DEBIAN"
changelog="$tree/$DEBIAN/changelog"
[ -f "$changelog" ] || die "no changelog at $changelog"

# prepend the +halokN entry; the heading names the packaging's source package
printf '%s (%s) %s; urgency=medium\n\n  * AMD PerfOpt IOMMU backport + Zen 5 build target.\n\n -- halo-ubuntu-kernel <kernel@localhost>  %s\n\n' \
  "$SOURCE_PKG" "$our_version" "$SERIES" "$(date -R)" > "$changelog.new" \
  || die "cannot write $changelog.new"
cat "$changelog" >> "$changelog.new" || die "cannot append the old changelog"
mv "$changelog.new" "$changelog" || die "cannot replace $changelog"

# the version assert runs BEFORE compiling: seconds, not hours
parsed=$(dpkg-parsechangelog -l"$changelog" -S Version) \
  || die "dpkg-parsechangelog failed on $changelog"
[ "$parsed" = "$our_version" ] \
  || die "changelog parses to '$parsed', expected $our_version"

# build-dep resolves against the environment's apt state (the CI container's);
# only the pinned fetch above uses the isolated deb-src state
( cd "$scratch" && apt-get build-dep -y "./$(basename -- "$1")" ) \
  || die "apt-get build-dep failed"

# The compiler decision is logged BEFORE the ~3h compile so a mismatch is
# diagnosable from the logs alone; the same value is asserted against the
# built .config's CONFIG_GCC_VERSION after the build.
if [ -n "$COMPILER_OVERRIDE" ]; then
  expect=${COMPILER_OVERRIDE#gcc-}
  echo "build-kernel: compiler: gcc=$COMPILER_OVERRIDE (COMPILER_OVERRIDE, passed to debian/rules as gcc=); CONFIG_GCC_VERSION must report gcc-$expect" >&2
else
  expect=$(gcc -dumpversion) || die "gcc unavailable to determine the native compiler version"
  echo "build-kernel: compiler: the packaging's native gcc-$expect (no COMPILER_OVERRIDE); CONFIG_GCC_VERSION must report gcc-$expect" >&2
fi

ccache_dir=${CCACHE_DIR:-$output/ccache}
# gcc= as a debian/rules command-line variable beats the packaging's plain
# gcc = gcc-13 assignment; ccache rides the masquerade dir first in PATH.
# fakeroot is meaningful only for non-root builds: under it, EVERY file
# metadata operation becomes an IPC round-trip to the single-threaded faked
# daemon, which multiplies the kernel build's millions of stat calls into
# ~10x wall time (root-caused via strace on the first slow local build). Our
# containers run as root — real uid 0 is recorded in the debs — so bare.
if [ "$(id -u)" = 0 ]; then fakeroot_cmd=(); else fakeroot_cmd=(fakeroot); fi
( cd "$tree" && PATH="/usr/lib/ccache:$PATH" CCACHE_DIR="$ccache_dir" CCACHE_MAXSIZE=5G \
    "${fakeroot_cmd[@]}" debian/rules clean ) || die "debian/rules clean failed"

# --- compiler-capability annotation pre-flight -------------------------------
# The packaging's annotations --check (inside stamp-prepare) compares the
# packaged config policies against what olddefconfig computes with THIS
# compiler. Building with a different compiler than the packaging pins
# (COMPILER_OVERRIDE=gcc-14 vs noble's pinned gcc-13) legitimately flips
# CONFIG_CC_HAS_* compiler-capability probes and fails the prepare stamp.
# Run the developer prepare target once as a pre-flight: on probe-only drift,
# repair via the packaging's own annotations --write and re-run; any other
# drift is a real config change and hard-fails here, seconds into the build.
mkdir -p "$output" || die "cannot create $output"
drift_log="$output/prepare-drift.log"
prepare_args=(prepare-generic)
[ -z "$COMPILER_OVERRIDE" ] || prepare_args+=(gcc="$COMPILER_OVERRIDE")
if ! ( cd "$tree" && PATH="/usr/lib/ccache:$PATH" CCACHE_DIR="$ccache_dir" CCACHE_MAXSIZE=5G \
    "${fakeroot_cmd[@]}" debian/rules "${prepare_args[@]}" ) >"$drift_log" 2>&1; then
  # shellcheck source=scripts/lib/annotation-drift.sh
  . "$REPO/scripts/lib/annotation-drift.sh"
  rc=0
  fixed=$(parse_check_config_drift "$(cat "$drift_log")") || rc=$?
  case "$rc" in
    0)
      while IFS= read -r pair; do
        opt=${pair%=*}
        ( cd "$tree" && python3 debian/scripts/misc/annotations \
            -f "$DEBIAN/config/annotations" --arch amd64 --flavour generic \
            --config "$opt" --write y ) \
          || die "annotations --write $opt=y failed (see $drift_log)"
        echo "build-kernel: annotations sync: $pair (compiler-capability probe)"
      done <<EOF
$fixed
EOF
      ( cd "$tree" && PATH="/usr/lib/ccache:$PATH" CCACHE_DIR="$ccache_dir" CCACHE_MAXSIZE=5G \
          "${fakeroot_cmd[@]}" debian/rules "${prepare_args[@]}" ) \
        || die "prepare still fails after annotation sync (see $drift_log)"
      ;;
    1)
      tail -20 "$drift_log" >&2
      die "prepare failed without config drift — see $drift_log"
      ;;
    *)
      tail -20 "$drift_log" >&2
      die "prepare failed with non-repairable config drift — see $drift_log"
      ;;
  esac
fi

rules_args=(binary-generic)
[ -z "$COMPILER_OVERRIDE" ] || rules_args+=(gcc="$COMPILER_OVERRIDE")
( cd "$tree" && PATH="/usr/lib/ccache:$PATH" CCACHE_DIR="$ccache_dir" CCACHE_MAXSIZE=5G \
    CONCURRENCY_LEVEL="$jobs" KCFLAGS="$kcflags" skipabi=true skipdbg=true \
    "${fakeroot_cmd[@]}" debian/rules "${rules_args[@]}" ) || die "binary-generic build failed"

# --- deb collection: publish allowlist, ignore known by-products -------------
# debs land in the parent of the source tree (dpkg-buildpackage behavior);
# binary-generic also produces packages we deliberately do not publish
# (linux-headers among them — the spec's build section), so those known
# by-products are ignored with a stdout record while anything genuinely
# unexpected still hard-fails. linux-lib-rust-<abi>-generic is a per-flavour
# binary of BOTH kernel source packages (verified in the noble/resolute
# archive Binary lists). Publication allowlist stays enforced downstream.
deb_src_dir=$tree/..
shopt -s nullglob
image_deb='' modules_deb=''
for deb in "$deb_src_dir"/*.deb "$deb_src_dir"/*.ddeb; do
  base=$(basename -- "$deb")
  case "$base" in
    linux-image-unsigned-*.deb) image_deb=$deb ;;
    linux-modules-*.deb)
      case "$base" in
        linux-modules-extra-*) die "unexpected modules-extra split — allowlist/payload review needed" ;;
        *) modules_deb=$deb ;;
      esac ;;
    *.ddeb) echo "build-kernel: ignoring ddeb: $base" ;;
    linux-headers-*.deb | linux-buildinfo-*.deb | linux-tools*.deb \
      | linux-cloud-tools*.deb | linux-libc-dev*.deb | linux-lib-rust-*.deb \
      | linux-bpf-dev*.deb | linux-main-modules-*.deb)
      echo "build-kernel: ignoring build by-product: $base" ;;
    *) die "unexpected .deb produced: $base — allowlist/payload review needed" ;;
  esac
done
shopt -u nullglob
[ -n "$image_deb" ] || die "no linux-image-unsigned deb in $deb_src_dir — build produced nothing publishable"
[ -n "$modules_deb" ] || die "no linux-modules deb in $deb_src_dir — build produced nothing publishable"

imgver=$(dpkg-deb -f "$image_deb" Version) || die "cannot read the version of $image_deb"
case "$imgver" in *"+halok$n") ;; *) die "image deb version '$imgver' does not end in +halok$n" ;; esac

# the RDMA stack must be in the published modules deb — proven per build.
# Path-anchored basename match: a bare "$ko.ko" grep would match fwctl.ko
# inside mlx5_fwctl.ko, making the fwctl check unable to fail. dpkg-deb -c
# lists full paths, and the kernel may compress modules (.xz/.zst).
for ko in mlx5_core mlx5_ib fwctl mlx5_fwctl; do
  dpkg-deb -c "$modules_deb" | grep -Eq "/$ko\.ko(\.xz|\.zst)?$" \
    || { echo "modules package lacks $ko — allowlist/payload review needed" >&2; exit 1; }
done

mkdir -p "$output/debs" || die "cannot create $output/debs"
for deb in "$image_deb" "$modules_deb"; do
  cp "$deb" "$output/debs/" || die "cannot copy $deb to $output/debs"
  echo "build-kernel: $(basename -- "$deb") -> $output/debs" >&2
done

# --- self-verification with real artifacts -----------------------------------
# CONFIG_GCC_VERSION from the built generic flavor .config proves the compiler
# override (or native choice) actually reached kbuild. Live builds confirmed
# the layout (see scripts/lib/selfcheck.sh): the kbuild dir is
# debian/build/build-generic; the headers staging dir carries a .config copy
# but no .cmd files.
config=$(selfcheck_find_generic_config "$tree") \
  || die "no built generic .config under $tree/debian — build-dir layout needs review"
# $expect was decided (and logged) before the build; here it is enforced
gcc_ver=$(sed -n 's/^CONFIG_GCC_VERSION=//p' "$config")
[ -n "$gcc_ver" ] || die "CONFIG_GCC_VERSION missing from $config"
[ "$((gcc_ver / 10000))" = "$expect" ] \
  || die "CONFIG_GCC_VERSION=$gcc_ver (gcc-$((gcc_ver / 10000))) but expected gcc-$expect"

# a .cmd file must show the znver5 flags actually reaching the compiler
sample=$(selfcheck_verify_znver5 "$tree") \
  || die "no .cmd file under $tree/debian contains -march=znver5 — KCFLAGS did not reach the compiler"
echo "build-kernel: znver5 confirmed in $sample" >&2

# ccache telemetry: zero hits is legitimate on a cold cache — a warning only
stats_file=$output/ccache-stats.txt
if PATH="/usr/lib/ccache:$PATH" CCACHE_DIR="$ccache_dir" ccache --print-stats > "$stats_file" 2>/dev/null; then
  hits=$(awk -F'\t' '$1 ~ /_hit$/ {s += $2} END {print s + 0}' "$stats_file")
  if [ "$hits" -eq 0 ]; then
    echo "build-kernel: WARNING: ccache recorded zero hits (cold cache is legitimate); stats: $stats_file" >&2
  else
    echo "build-kernel: ccache hits: $hits (stats: $stats_file)" >&2
  fi
else
  echo "build-kernel: WARNING: ccache --print-stats failed; no stats recorded" >&2
fi
