# shellcheck shell=bash
# scripts/lib/selfcheck.sh: post-build artifact self-verification helpers —
# sourced by run-tests.sh. Fixtures are built in a temp dir per test: a
# built-tree shape where the generic .config lives in BOTH the headers
# package staging dir and the kbuild build dir, while .cmd files exist ONLY
# under the kbuild build dir (the layout confirmed on the first live build,
# which the original dirname(.config) search got wrong).

. scripts/lib/selfcheck.sh

make_fixture() {  # <znver5: yes|no> <build_config: yes|no> <headers_config: yes|no>
  local d; d=$(mktemp -d)
  mkdir -p "$d/tree/debian/build/build-generic"
  if [ "$2" = yes ]; then
    printf 'CONFIG_GCC_VERSION=140200\n' > "$d/tree/debian/build/build-generic/.config"
  fi
  if [ "$3" = yes ]; then
    mkdir -p "$d/tree/debian/linux-headers-7.0.0-38-generic/usr/src/linux-headers-7.0.0-38-generic"
    printf 'CONFIG_GCC_VERSION=140200\n' \
      > "$d/tree/debian/linux-headers-7.0.0-38-generic/usr/src/linux-headers-7.0.0-38-generic/.config"
  fi
  if [ "$1" = yes ]; then
    printf 'savedcmd_drivers/foo.o := gcc -c -o drivers/foo.o -march=znver5 -mtune=znver5 drivers/foo.c\n' \
      > "$d/tree/debian/build/build-generic/.drivers.foo.o.cmd"
  else
    printf 'savedcmd_drivers/foo.o := gcc -c -o drivers/foo.o drivers/foo.c\n' \
      > "$d/tree/debian/build/build-generic/.drivers.foo.o.cmd"
  fi
  echo "$d"
}

test_verify_znver5_finds_build_dir_cmd() {
  # the live-build failure shape: .cmd files exist only under the kbuild
  # build dir, so the search must cover it, not just dirname(.config)
  local d out rc
  d=$(make_fixture yes yes yes)
  out=$(selfcheck_verify_znver5 "$d/tree"); rc=$?
  assert_eq "$rc" "0" "znver5 present -> rc 0" || return 1
  case "$out" in
    */debian/build/build-generic/*) : ;;
    *) echo "expected a path under the kbuild build dir, got [$out]"; return 1 ;;
  esac
  rm -rf "$d"
}

test_verify_znver5_finds_cmd_without_headers_config() {
  # even when only the build dir exists at all
  local d out rc
  d=$(make_fixture yes yes no)
  out=$(selfcheck_verify_znver5 "$d/tree"); rc=$?
  assert_eq "$rc" "0" "znver5 present (no headers copy) -> rc 0" || return 1
  [ -n "$out" ] || { echo "sample path must be printed"; return 1; }
  rm -rf "$d"
}

test_verify_znver5_absent_fails_empty() {
  local d out rc
  d=$(make_fixture no yes yes)
  out=$(selfcheck_verify_znver5 "$d/tree"); rc=$?
  assert_eq "$rc" "1" "no znver5 anywhere -> rc 1" || return 1
  assert_eq "$out" "" "no sample printed on failure" || return 1
  rm -rf "$d"
}

test_verify_znver5_cmd_without_flag_fails() {
  # a .cmd tree that lacks the flag must be indistinguishable from no .cmd
  local d out rc
  d=$(make_fixture no yes no)
  out=$(selfcheck_verify_znver5 "$d/tree"); rc=$?
  assert_eq "$rc" "1" "cmd file without znver5 -> rc 1" || return 1
  assert_eq "$out" "" "no sample printed on failure" || return 1
  rm -rf "$d"
}

test_find_generic_config_prefers_build_dir() {
  # the kbuild dir's .config is the one the build actually consumed
  local d out
  d=$(make_fixture yes yes yes)
  out=$(selfcheck_find_generic_config "$d/tree")
  case "$out" in
    */debian/build/build-generic/.config) : ;;
    *) echo "expected the build-dir .config, got [$out]"; return 1 ;;
  esac
  rm -rf "$d"
}

test_find_generic_config_falls_back_to_headers_copy() {
  local d out
  d=$(make_fixture yes no yes)
  out=$(selfcheck_find_generic_config "$d/tree")
  case "$out" in
    */usr/src/linux-headers-*/.config) : ;;
    *) echo "expected the headers-staging fallback, got [$out]"; return 1 ;;
  esac
  rm -rf "$d"
}

test_find_generic_config_missing_fails() {
  local d out rc
  d=$(make_fixture yes no no)
  out=$(selfcheck_find_generic_config "$d/tree"); rc=$?
  assert_eq "$rc" "1" "no generic .config -> rc 1" || return 1
  assert_eq "$out" "" "no path printed on failure" || return 1
  rm -rf "$d"
}
