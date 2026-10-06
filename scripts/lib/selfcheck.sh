# shellcheck shell=bash
# selfcheck.sh — post-build artifact self-verification helpers for
# build-kernel.sh. Each function takes the built source tree and prints its
# finding on stdout; rc 0 = verified, 1 = missing (caller decides die/warn).
#
# Layout notes confirmed on the first live builds: the kbuild build dir is
# debian/build/build-generic (its .config is the one the build consumed, its
# .cmd files record the flags the compiler actually saw), while the headers
# package staging dir also carries a .config copy but NO .cmd files.

# selfcheck_find_generic_config TREE — path of the built generic flavor
# .config; prefers the kbuild build dir, falls back to the headers package
# staging copy. rc 1 with empty stdout when neither exists.
selfcheck_find_generic_config() {
  local tree=$1 candidates found=
  candidates=$(find "$tree/debian" -type f -name .config 2>/dev/null | grep 'generic') \
    || return 1
  found=$(printf '%s\n' "$candidates" | grep '/debian/build/' | head -1) || true
  [ -n "$found" ] || found=$(printf '%s\n' "$candidates" | head -1)
  [ -n "$found" ] || return 1
  echo "$found"
}

# selfcheck_verify_znver5 TREE — a .cmd file recording -march=znver5 proves
# KCFLAGS reached the compiler. Searches the whole debian/ tree so the
# kbuild build dir is always covered regardless of which .config copy was
# found. Prints the sample path on success; rc 1 with empty stdout when no
# .cmd carries the flag.
selfcheck_verify_znver5() {
  local tree=$1 sample
  sample=$(grep -rl -m1 --include='*.cmd' -e '-march=znver5' "$tree/debian" 2>/dev/null | head -1) || true
  [ -n "$sample" ] || return 1
  echo "$sample"
}
