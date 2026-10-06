#!/usr/bin/env bash
# make-dummy-deb.sh — build a tiny REAL deb for the tests: one small data file
# and a control with Package/Version (and Depends when given). Real dpkg-deb
# output, so the index and apt tests exercise real deb payloads, not mocks.
# usage: make-dummy-deb.sh <output-dir> <package-name> <version> [depends]
#   depends  Depends value to embed; 'none' omits the field entirely
#            (a dependency-free deb, e.g. an e2e target that must resolve
#            against the throwaway repo alone). Default: 'libc6 (>= 1.0)'.
# Writes <output-dir>/<package-name>_<version>_all.deb (Architecture: all).
set -u

die() { echo "make-dummy-deb: $*" >&2; exit 1; }

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
  die "usage: make-dummy-deb.sh <output-dir> <package-name> <version> [depends]"
fi
out="$1" pkg="$2" ver="$3" depends="${4:-libc6 (>= 1.0)}"

case "$pkg" in *[!A-Za-z0-9.+-]*) die "package name '$pkg' has characters invalid in a deb name" ;; esac

mkdir -p "$out" || die "cannot create output dir $out"
staging=$(mktemp -d) || die "mktemp -d failed"
trap 'rm -rf "$staging"' EXIT
# mktemp -d is 0700; dpkg-deb preserves the staging dir's mode as the data
# tarball's top-level './' entry, so make the package root world-readable
chmod 0755 "$staging" || die "chmod 0755 $staging failed"
mkdir -p "$staging/DEBIAN" "$staging/usr/share/$pkg" || die "cannot create staging tree"
{
  printf 'Package: %s\n' "$pkg"
  printf 'Version: %s\n' "$ver"
  printf 'Section: kernel\n'
  printf 'Priority: optional\n'
  printf 'Architecture: all\n'
  printf 'Maintainer: halo-ubuntu-kernel <andrewachen@users.noreply.github.com>\n'
  case "$depends" in
    none) ;;
    *) printf 'Depends: %s\n' "$depends" ;;
  esac
  printf 'Description: dummy test package %s\n' "$pkg"
  printf ' Throwaway payload exercising the apt index and publisher tests.\n'
} > "$staging/DEBIAN/control" || die "cannot write control"
echo "dummy payload for $pkg $ver" > "$staging/usr/share/$pkg/README"

dpkg-deb --build --root-owner-group "$staging" "$out/${pkg}_${ver}_all.deb" >/dev/null \
  || die "dpkg-deb --build failed"
