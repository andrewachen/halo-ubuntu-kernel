# version arithmetic + tag mapping tests — sourced by run-tests.sh.
. scripts/lib/version.sh

test_append_suffix_basic() { assert_eq "$(append_halo_suffix '7.0.0-38.38~24.04.4' 1)" '7.0.0-38.38~24.04.4+halok1' "append"; }
test_suffix_sorts_above_stock() { dpkg --compare-versions '7.0.0-38.38~24.04.4' lt '7.0.0-38.38~24.04.4+halok2'; }
test_ours_sorts_below_next_stock_abi_and_respin() {
  dpkg --compare-versions '7.0.0-38.38~24.04.4+halok9' lt '7.0.0-39.39~24.04.1' &&
    dpkg --compare-versions '7.0.0-38.38~24.04.4+halok9' lt '7.0.0-38.38~24.04.5'
}
test_next_halo_n() {
  assert_eq "$(next_halo_n '7.0.0-38.38~24.04.4')" 1 "first" &&
    assert_eq "$(next_halo_n '7.0.0-38.38~24.04.4' '7.0.0-38.38~24.04.4+halok1' \
      '7.0.0-38.38~24.04.4+halok3' '7.0.0-37.37~24.04.2+halok5')" 4 "max same-upstream"
}
test_strip_suffix() { assert_eq "$(strip_halo_suffix '7.0.0-38.38~24.04.4+halok3')" '7.0.0-38.38~24.04.4' "strip"; }
test_newest_deb_version() {
  assert_eq "$(printf 'Version: 7.0.0-38.38~24.04.4\n\nVersion: 7.0.0-41.41~24.04.5\n' | newest_deb_version)" '7.0.0-41.41~24.04.5' &&
    assert_eq "$(printf 'Version: 7.0.0-39.39\n\nVersion: 7.0.0-26.26~26.04.9\n' | newest_deb_version)" '7.0.0-39.39'
}
test_tag_ref_safe() {
  local t; t=$(tag_for_version noble '7.0.0-38.38~24.04.4+halok1')
  assert_eq "$t" 'noble-7.0.0-38.38_24.04.4+halok1' "sanitized" &&
    git check-ref-format "refs/tags/$t"
}
test_tag_round_trip() {
  local v='7.0.0-38.38~24.04.4+halok1'
  assert_eq "$(version_from_tag "$(tag_for_version resolute "$v")")" "$v" "reverse"
}
test_empty_array_under_set_u() { set -u; next_halo_n '7.0.0-38.38~24.04.4' >/dev/null; set +u; }
test_tag_rejects_epoch_evr() {
  if tag_for_version noble '1:7.0.0-38.38~24.04.4+halok1' >/dev/null 2>&1; then
    echo "tag_for_version must reject an EVR with an epoch (:)" >&2
    return 1
  fi
}
test_tag_rejects_whitespace_evr() {
  if tag_for_version noble '7.0.0-38.38 24.04.4' >/dev/null 2>&1; then
    echo "tag_for_version must reject an EVR with whitespace" >&2
    return 1
  fi
}
