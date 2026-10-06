# annotation-drift parser tests — sourced by run-tests.sh.
. scripts/lib/annotation-drift.sh

DRIFT_SAMPLE='check-config: loading annotations from /src/debian.hwe-7.0/config/annotations
check-config: CONFIG_CC_HAS_KASAN_SW_TAGS changed from - to y: policy<{'"'"'amd64'"'"': '"'"'-'"'"', '"'"'arm64'"'"': '"'"'y'"'"'}>)
check-config: CONFIG_CC_HAS_MIN_FUNCTION_ALIGNMENT changed from - to y: policy<{'"'"'amd64'"'"': '"'"'-'"'"', '"'"'arm64'"'"': '"'"'-'"'"', '"'"'armhf'"'"': '"'"'-'"'"', '"'"'ppc64el'"'"': '"'"'-'"'"', '"'"'riscv64'"'"': '"'"'-'"'"', '"'"'s390x'"'"': '"'"'-'"'"'}>)
check-config: CONFIG_CC_HAS_SANE_FUNCTION_ALIGNMENT changed from - to y: policy<{'"'"'amd64'"'"': '"'"'-'"'"', '"'"'arm64'"'"': '"'"'-'"'"', '"'"'armhf'"'"': '"'"'-'"'"', '"'"'ppc64el'"'"': '"'"'-'"'"', '"'"'riscv64'"'"': '"'"'-'"'"', '"'"'s390x'"'"': '"'"'-'"'"'}>)
check-config: 3 config options have changed'

test_drift_parses_real_cc_has_sample() {
  local out rc
  out=$(parse_check_config_drift "$DRIFT_SAMPLE"); rc=$?
  assert_eq "$rc" 0 "repairable drift returns 0" &&
    assert_eq "$out" "$(printf 'CONFIG_CC_HAS_KASAN_SW_TAGS=y\nCONFIG_CC_HAS_MIN_FUNCTION_ALIGNMENT=y\nCONFIG_CC_HAS_SANE_FUNCTION_ALIGNMENT=y')" "three probes parsed"
}

test_drift_no_drift_returns_1() {
  local out rc sample
  sample=$(printf 'check-config: loading annotations from /x\ncheck-config: no config options have changed\n')
  out=$(parse_check_config_drift "$sample"); rc=$?
  assert_eq "$rc" 1 "no drift returns 1" && assert_eq "$out" "" "no pairs printed"
}

test_drift_rejects_non_probe_drift() {
  # even with repairable probes present, one non-probe drift must make the
  # verdict fatal (rc=2) and print NOTHING repairable — the caller must abort
  local out rc d sample
  d=$(mktemp -d)
  trap 'rm -rf "$d"' EXIT
  sample=$(printf '%s\ncheck-config: CONFIG_KASAN_SW_TAGS changed from - to y: policy<...>\n' "$DRIFT_SAMPLE")
  out=$(parse_check_config_drift "$sample" 2>"$d/err"); rc=$?
  assert_eq "$rc" 2 "non-probe drift is fatal" && assert_eq "$out" "" "no repairable output on fatal verdict" &&
    grep -q "NOT auto-repairable" "$d/err"
}

test_drift_rejects_probe_to_n() {
  local out rc d sample
  d=$(mktemp -d)
  trap 'rm -rf "$d"' EXIT
  sample=$(printf 'check-config: CONFIG_CC_HAS_KASAN_SW_TAGS changed from y to n: policy<...>\n')
  out=$(parse_check_config_drift "$sample" 2>"$d/err"); rc=$?
  assert_eq "$rc" 2 "probe drifting to n is fatal" && assert_eq "$out" "" "nothing repairable printed"
}

test_drift_ignores_non_check_lines() {
  local out rc sample
  sample=$(printf 'make[1]: Entering directory\nsome random build noise\n')
  out=$(parse_check_config_drift "$sample"); rc=$?
  assert_eq "$rc" 1 "noise is not drift"
}
