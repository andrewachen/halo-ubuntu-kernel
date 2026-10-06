# shellcheck shell=bash
# build-meta-deb.sh: control content, ABI derivation, and output-file policy —
# sourced by run-tests.sh. Black-box CLI tests: real dpkg-deb on the produced
# deb, no network, no mocks. Every test builds into its own mktemp dir.

SCRIPT="$PWD/scripts/build-meta-deb.sh"
EVR=7.0.0-38.38~24.04.4+halok1

build_meta() {  # <series> <evr> <output-dir>
  "$SCRIPT" --series "$1" --evr "$2" --output "$3"
}

test_meta_depends_line_exact() {
  # the full three-term Depends line is the upgrade mechanism: the first term's
  # exact-EVR pin forces the right kernel when a newer meta lands, and the
  # firmware terms ride the meta because the stock metas that guaranteed them
  # are removed by our install
  local d depends
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  depends=$(dpkg-deb -f "$d/linux-image-halo-noble_${EVR}_amd64.deb" Depends)
  assert_eq "$depends" \
    "linux-image-unsigned-7.0.0-38-generic (= $EVR), linux-modules-7.0.0-38-generic (= $EVR), linux-main-modules-zfs-7.0.0-38-generic (= 7.0.0-38.38~24.04.4), linux-main-modules-v4l2loopback-7.0.0-38-generic (= 7.0.0-38.38~24.04.4), linux-firmware, amd64-microcode" \
    "meta Depends line" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_split_modules_pin_stock_evr() {
  # Option A: the split modules (zfs, v4l2loopback) are NOT built or published
  # by us — the meta Depends on Ubuntu's own debs at the STOCK EVR (the halok
  # suffix stripped). Same source version and ABI as our rebuild, so they are
  # vermagic/CRC-compatible; this mirrors stock linux-image-generic's Depends.
  local d depends
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  depends=$(dpkg-deb -f "$d/linux-image-halo-noble_${EVR}_amd64.deb" Depends)
  case "$depends" in
    *"linux-main-modules-zfs-7.0.0-38-generic (= 7.0.0-38.38~24.04.4)"*) ;;
    *) echo "noble meta must pin stock linux-main-modules-zfs at the stock EVR" >&2; rm -rf "$d"; return 1 ;;
  esac
  case "$depends" in
    *"linux-main-modules-v4l2loopback-7.0.0-38-generic (= 7.0.0-38.38~24.04.4)"*) ;;
    *) echo "noble meta must pin stock linux-main-modules-v4l2loopback at the stock EVR" >&2; rm -rf "$d"; return 1 ;;
  esac
  rm -rf "$d"
}

test_meta_split_modules_resolute_zfs_only() {
  # resolute's stock meta pulls only zfs (no v4l2loopback term) — the meta
  # must mirror that, not blanket-add noble's split list
  local d depends revr=7.0.0-38.38+halok1
  d=$(mktemp -d)
  build_meta resolute "$revr" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  depends=$(dpkg-deb -f "$d/linux-image-halo-resolute_${revr}_amd64.deb" Depends)
  case "$depends" in
    *"linux-main-modules-zfs-7.0.0-38-generic (= 7.0.0-38.38)"*) ;;
    *) echo "resolute meta must pin stock linux-main-modules-zfs at the stock EVR" >&2; rm -rf "$d"; return 1 ;;
  esac
  case "$depends" in
    *v4l2loopback*) echo "resolute meta must NOT depend on v4l2loopback" >&2; rm -rf "$d"; return 1 ;;
  esac
  rm -rf "$d"
}

test_meta_control_fields() {
  local d pkg ver arch
  d=$(mktemp -d)
  build_meta resolute "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  local deb="$d/linux-image-halo-resolute_${EVR}_amd64.deb"
  pkg=$(dpkg-deb -f "$deb" Package)
  ver=$(dpkg-deb -f "$deb" Version)
  arch=$(dpkg-deb -f "$deb" Architecture)
  # each assert returns on its own failure — a multi-assert test must not mask
  assert_eq "$pkg" "linux-image-halo-resolute" "Package" || { rm -rf "$d"; return 1; }
  assert_eq "$ver" "$EVR" "Version (== EVR)" || { rm -rf "$d"; return 1; }
  assert_eq "$arch" amd64 "Architecture" || { rm -rf "$d"; return 1; }
  # the remaining fixed control fields are contract too
  dpkg-deb -f "$deb" Section | grep -qx kernel || {
    echo "meta Section must be kernel" >&2; rm -rf "$d"; return 1; }
  dpkg-deb -f "$deb" Priority | grep -qx optional || {
    echo "meta Priority must be optional" >&2; rm -rf "$d"; return 1; }
  dpkg-deb -f "$deb" Maintainer | grep -qx 'halo-ubuntu-kernel <andrewachen@users.noreply.github.com>' || {
    echo "meta Maintainer must be the public noreply identity" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_abi_derivation_simple_shape() {
  # second EVR shape pinned: 7.0.0-39.39 -> abi 7.0.0-39, driven through the
  # full Depends line exactly like the primary shape test above
  local d depends
  d=$(mktemp -d)
  build_meta noble 7.0.0-39.39 "$d" >/dev/null 2>&1 || {
    echo "meta build with the simple EVR must succeed" >&2; rm -rf "$d"; return 1; }
  depends=$(dpkg-deb -f "$d/linux-image-halo-noble_7.0.0-39.39_amd64.deb" Depends)
  assert_eq "$depends" \
    "linux-image-unsigned-7.0.0-39-generic (= 7.0.0-39.39), linux-modules-7.0.0-39-generic (= 7.0.0-39.39), linux-main-modules-zfs-7.0.0-39-generic (= 7.0.0-39.39), linux-main-modules-v4l2loopback-7.0.0-39-generic (= 7.0.0-39.39), linux-firmware, amd64-microcode" \
    "abi from the simple EVR" || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_output_filename_pattern() {
  local d
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  [ -f "$d/linux-image-halo-noble_${EVR}_amd64.deb" ] || {
    echo "expected output deb at $d/linux-image-halo-noble_${EVR}_amd64.deb" >&2
    rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_deb_is_well_formed_control_only() {
  local d
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  local deb="$d/linux-image-halo-noble_${EVR}_amd64.deb"
  dpkg-deb --info "$deb" >/dev/null 2>&1 || {
    echo "dpkg-deb --info must accept the produced deb" >&2; rm -rf "$d"; return 1; }
  # control-only: no kernel modules and no firmware payload inside
  if dpkg-deb -c "$deb" | grep -Eq '\.ko(\.gz|\.xz|\.zst)?$|/firmware/'; then
    echo "meta deb must be control-only (no kernel or firmware payload)" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

test_meta_rejects_malformed_evr() {
  # usage error, not a crash: the exact code distinguishes them
  local d rc=0
  d=$(mktemp -d)
  "$SCRIPT" --series noble --evr 'not a version' --output "$d" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || { echo "malformed EVR must be a usage error (exit 2), got $rc" >&2; rm -rf "$d"; return 1; }
  if [ -n "$(ls -A "$d")" ]; then
    echo "malformed EVR must write no output: $(ls -A "$d")" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

test_meta_rejects_evr_missing_revision() {
  # no '-<revision>' means the ABI derivation has nothing to key off — usage error
  local d rc=0
  d=$(mktemp -d)
  "$SCRIPT" --series noble --evr 7.0.0 --output "$d" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || { echo "EVR without a revision must be a usage error (exit 2), got $rc" >&2; rm -rf "$d"; return 1; }
  if [ -n "$(ls -A "$d")" ]; then
    echo "rejected EVR must write no output: $(ls -A "$d")" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

test_meta_rejects_evr_with_epoch() {
  # an epoch (':') would be unsound for the ABI derivation — usage error
  local d rc=0
  d=$(mktemp -d)
  "$SCRIPT" --series noble --evr '1:7.0.0-38.38' --output "$d" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || { echo "EVR with an epoch must be a usage error (exit 2), got $rc" >&2; rm -rf "$d"; return 1; }
  if [ -n "$(ls -A "$d")" ]; then
    echo "rejected EVR must write no output: $(ls -A "$d")" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

test_meta_package_root_is_world_readable() {
  # the data tarball's top-level './' entry preserves the staging dir's mode —
  # a 0700 staging dir would make installing the deb chmod its target to 0700
  local d first
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  first=$(dpkg-deb -c "$d/linux-image-halo-noble_${EVR}_amd64.deb" | head -1)
  printf '%s\n' "$first" | grep -Eq '^drwxr-xr-x .*\./$' || {
    echo "package root './' entry must be mode drwxr-xr-x, got: $first" >&2
    rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_has_no_maintainer_scripts() {
  # the control archive must hold only 'control' — no postinst/postrm, no conffiles
  local d
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "meta build must succeed" >&2; rm -rf "$d"; return 1; }
  local deb="$d/linux-image-halo-noble_${EVR}_amd64.deb"
  if dpkg-deb --info "$deb" | grep -Eq 'postinst|postrm|preinst|prerm|conffiles'; then
    echo "meta deb must not carry maintainer scripts or conffiles" >&2
    rm -rf "$d"; return 1
  fi
  dpkg-deb --info "$deb" | grep -Eq '[0-9]+ bytes, +[0-9]+ lines +control$' || {
    echo "control-archive listing must name only the control file" >&2
    rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_rejects_unknown_series() {
  local d rc=0
  d=$(mktemp -d)
  "$SCRIPT" --series nosuchseries --evr "$EVR" --output "$d" >/dev/null 2>"$d/err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "unknown series must fail" >&2; rm -rf "$d"; return 1; }
  grep -q 'nosuchseries' "$d/err" || {
    echo "error must name the offending series" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_refuses_to_overwrite_existing() {
  local d before after rc=0
  d=$(mktemp -d)
  build_meta noble "$EVR" "$d" >/dev/null 2>&1 || {
    echo "first meta build must succeed" >&2; rm -rf "$d"; return 1; }
  local deb="$d/linux-image-halo-noble_${EVR}_amd64.deb"
  before=$(md5sum "$deb")
  "$SCRIPT" --series noble --evr "$EVR" --output "$d" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "rebuilding the same deb must refuse to overwrite" >&2; rm -rf "$d"; return 1; }
  after=$(md5sum "$deb")
  [ "$before" = "$after" ] || {
    echo "the refused overwrite still modified the existing deb" >&2; rm -rf "$d"; return 1; }
  rm -rf "$d"
}

test_meta_print_control_has_no_side_effects() {
  # --print-control must print the exact Depends line and create nothing: run
  # it from a pristine empty cwd and assert no files land there
  local d out
  d=$(mktemp -d)
  out=$(mktemp)
  (cd "$d" && "$SCRIPT" --series noble --evr "$EVR" --print-control) >"$out" \
    || { echo "--print-control failed" >&2; rm -rf "$d"; rm -f "$out"; return 1; }
  grep -qxF "Depends: linux-image-unsigned-7.0.0-38-generic (= $EVR), linux-modules-7.0.0-38-generic (= $EVR), linux-main-modules-zfs-7.0.0-38-generic (= 7.0.0-38.38~24.04.4), linux-main-modules-v4l2loopback-7.0.0-38-generic (= 7.0.0-38.38~24.04.4), linux-firmware, amd64-microcode" "$out" || {
    echo "--print-control must print the exact Depends line" >&2
    rm -rf "$d"; rm -f "$out"; return 1; }
  if [ -n "$(ls -A "$d")" ]; then
    echo "--print-control created files in the cwd: $(ls -A "$d")" >&2
    rm -rf "$d"; rm -f "$out"; return 1
  fi
  rm -rf "$d"; rm -f "$out"
}
