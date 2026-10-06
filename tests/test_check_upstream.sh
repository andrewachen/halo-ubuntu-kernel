# shellcheck shell=bash
# check-upstream.sh change detection + helper arg handling — sourced by run-tests.sh.
# Black-box CLI tests: no network, no mocks. fixture written into each test's mktemp dir.

# fixture: realistic two-entry apt-cache showsrc output; newest = 7.0.0-38.38~24.04.4
write_apt_fixture() {  # <dir> — writes <dir>/apt-showsrc.txt
  cat > "$1/apt-showsrc.txt" <<'EOF'
Package: linux-hwe-7.0
Binary: linux-image-unsigned-7.0.0-34.34-generic
Architecture: all
Version: 7.0.0-34.34~24.04.1
Maintainer: Ubuntu Kernel Team <kernel-team@lists.ubuntu.com>
Depends: linux-hwe-7.0-7.0.0-34.34

Package: linux-hwe-7.0
Binary: linux-image-unsigned-7.0.0-38.38-generic
Architecture: all
Version: 7.0.0-38.38~24.04.4
Maintainer: Ubuntu Kernel Team <kernel-team@lists.ubuntu.com>
Depends: linux-hwe-7.0-7.0.0-38.38

EOF
}

test_new_upstream_triggers_changed() {
  local d out
  d=$(mktemp -d)
  write_apt_fixture "$d"
  printf '7.0.0-34.34~24.04.4+halok1\n' > "$d/published.txt"
  out=$(scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt" \
        --published-file "$d/published.txt")
  assert_eq "$out" '{"series":"noble","upstream_version":"7.0.0-38.38~24.04.4","halo_n":1,"changed":true}' \
    "new upstream" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_already_published_is_unchanged() {
  local d out
  d=$(mktemp -d)
  write_apt_fixture "$d"
  printf '7.0.0-38.38~24.04.4+halok1\n' > "$d/published.txt"
  out=$(scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt" \
        --published-file "$d/published.txt")
  assert_eq "$out" '{"series":"noble","upstream_version":"7.0.0-38.38~24.04.4","halo_n":2,"changed":false}' \
    "unchanged documents next halo_n" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_index_packages_counts_as_published() {
  local d out
  d=$(mktemp -d)
  write_apt_fixture "$d"
  cat > "$d/Packages" <<'EOF'
Package: linux-image-unsigned-7.0.0-38-generic
Version: 7.0.0-38.38~24.04.4+halok1
Architecture: amd64
Size: 10485760
SHA256: 0123456789abcdef
Filename: pool/main/l/linux-hwe-7.0/linux-image-unsigned-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb

Package: linux-modules-7.0.0-38-generic
Version: 7.0.0-38.38~24.04.4+halok1
Architecture: amd64
Size: 31457280
SHA256: fedcba9876543210
Filename: pool/main/l/linux-hwe-7.0/linux-modules-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb

EOF
  out=$(scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt" \
        --index "$d/Packages")
  assert_eq "$out" '{"series":"noble","upstream_version":"7.0.0-38.38~24.04.4","halo_n":2,"changed":false}' \
    "--index counts as published" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_force_bumps_halo_n() {
  local d out
  d=$(mktemp -d)
  write_apt_fixture "$d"
  printf '7.0.0-38.38~24.04.4+halok1\n' > "$d/published.txt"
  out=$(scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt" \
        --published-file "$d/published.txt" --force)
  assert_eq "$out" '{"series":"noble","upstream_version":"7.0.0-38.38~24.04.4","halo_n":2,"changed":true}' \
    "--force rebuild bumps N" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_no_published_set_is_changed() {
  local d out
  d=$(mktemp -d)
  write_apt_fixture "$d"
  out=$(scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt")
  assert_eq "$out" '{"series":"noble","upstream_version":"7.0.0-38.38~24.04.4","halo_n":1,"changed":true}' \
    "no published versions is a change" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_empty_published_file_is_fresh() {
  local d out
  d=$(mktemp -d)
  write_apt_fixture "$d"
  : > "$d/published.txt"   # readable but blank = first-publication case, not an abort
  out=$(scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt" \
        --published-file "$d/published.txt")
  assert_eq "$out" '{"series":"noble","upstream_version":"7.0.0-38.38~24.04.4","halo_n":1,"changed":true}' \
    "blank published file is an empty published set" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_apt_src_update_offline_no_crash() {
  # review findings 1+2+3, offline: a fresh workdir must not abort update with
  # "lists/partial is missing", update must leave stdout clean for the helper to
  # hand to check-upstream.sh, and showsrc must run apt-cache (no "Invalid
  # operation showsrc"). Uses a temp REPO with an empty-pockets series so nothing
  # touches the network.
  local d wd out rc
  d=$(mktemp -d)
  mkdir -p "$d/series/offseries"
  printf 'SERIES=offseries\nSOURCE_PKG=linux\nPATCHSET=v7.0\nPOCKETS=""\n' > "$d/series/offseries/series.env"
  . scripts/lib/apt-src.sh
  REPO="$d"
  wd=$(mktemp -d)
  out=$(mktemp)
  apt_src_update offseries "$wd" >"$out" 2>"$d/update-err"
  rc=$?
  [ "$rc" -eq 0 ] || {
    echo "apt_src_update must exit 0 on a fresh isolated workdir (got $rc):" >&2
    cat "$d/update-err" >&2
    rm -rf "$d" "$wd" "$out"; return 1
  }
  if [ -s "$out" ]; then
    echo "apt_src_update must not write progress to stdout (isolated-output contract):" >&2
    cat "$out" >&2
    rm -rf "$d" "$wd" "$out"; return 1
  fi
  # offline showsrc has no package lists: apt-cache exits 100 explaining that no
  # deb-src URIs produced a Sources index. That message — not "Invalid operation
  # showsrc" (the apt-get-call bug) — is what we pin.
  apt_src_showsrc offseries "$wd" linux >"$d/showsrc-out" 2>"$d/showsrc-err"
  rc=$?
  if grep -q "Invalid operation" "$d/showsrc-err"; then
    echo "apt_src_showsrc must call apt-cache, not apt-get showsrc:" >&2
    cat "$d/showsrc-err" >&2
    rm -rf "$d" "$wd" "$out"; return 1
  fi
  if [ "$rc" -ne 100 ] || ! grep -q "deb-src" "$d/showsrc-err"; then
    echo "apt_src_showsrc offline must be apt-cache's 100 + deb-src explanation (got rc=$rc):" >&2
    cat "$d/showsrc-err" >&2
    rm -rf "$d" "$wd" "$out"; return 1
  fi
  rm -rf "$d" "$wd" "$out"
}

test_apt_src_download_offline_pins_apt_get_source() {
  # the pinned-download helper must run apt-get source --download-only (not
  # crash) and, offline, fail with apt's no-deb-src explanation — same
  # isolated-state contract as the update/showsrc tests above. Uses a temp
  # REPO with an empty-pockets series so nothing touches the network.
  local d wd rc=0
  d=$(mktemp -d)
  mkdir -p "$d/series/offseries"
  printf 'SERIES=offseries\nSOURCE_PKG=linux\nPATCHSET=v7.0\nPOCKETS=""\n' > "$d/series/offseries/series.env"
  . scripts/lib/apt-src.sh
  REPO="$d"
  wd=$(mktemp -d)
  ( cd "$wd" && apt_src_download offseries "$wd" "linux=1.0" ) >"$d/dl-out" 2>"$d/dl-err" || rc=$?
  if [ "$rc" -ne 100 ] || ! grep -q "deb-src" "$d/dl-err"; then
    echo "apt_src_download offline must be apt-get's 100 + deb-src explanation (got rc=$rc):" >&2
    cat "$d/dl-err" >&2
    rm -rf "$d" "$wd"; return 1
  fi
  rm -rf "$d" "$wd"
}

test_empty_apt_output_fails() {
  local d
  d=$(mktemp -d)
  : > "$d/apt-showsrc.txt"
  if scripts/check-upstream.sh --series noble --apt-output "$d/apt-showsrc.txt" >/dev/null 2>"$d/err"; then
    echo "check-upstream must fail on apt output with no Version: lines" >&2
    rm -rf "$d"; return 1
  fi
  grep -q "apt-showsrc.txt" "$d/err" || {
    echo "check-upstream error must name the offending file" >&2
    rm -rf "$d"; return 1
  }
  rm -rf "$d"
}

test_series_env_values() {
  . series/noble/series.env
  assert_eq "$SERIES" noble "noble SERIES" &&
    assert_eq "$SOURCE_PKG" linux-hwe-7.0 "noble SOURCE_PKG" &&
    assert_eq "$PATCHSET" v7.0 "noble PATCHSET" &&
    assert_eq "$POCKETS" "noble noble-updates noble-security" "noble POCKETS" &&
    . series/resolute/series.env &&
    assert_eq "$SERIES" resolute "resolute SERIES" &&
    assert_eq "$SOURCE_PKG" linux "resolute SOURCE_PKG" &&
    assert_eq "$PATCHSET" v7.0 "resolute PATCHSET" &&
    assert_eq "$POCKETS" "resolute resolute-updates resolute-security" "resolute POCKETS"
}

test_helper_requires_series_arg() {
  local rc
  scripts/check-upstream-helper.sh >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { echo "helper with no args must exit 2 (usage), got $rc" >&2; return 1; }
}

test_helper_rejects_unknown_series_before_network() {
  local rc err
  err=$(mktemp)
  scripts/check-upstream-helper.sh nosuchseries >/dev/null 2>"$err"
  rc=$?
  [ "$rc" -eq 1 ] || {
    echo "helper with unknown series must exit 1, got $rc" >&2
    rm -f "$err"; return 1; }
  # the message must say WHY: no series definition at series/<name>/series.env
  grep -q 'no series definition at series/nosuchseries/series.env' "$err" || {
    echo "unknown-series refusal must name the missing series definition:" >&2
    cat "$err" >&2
    rm -f "$err"; return 1; }
  rm -f "$err"
}
