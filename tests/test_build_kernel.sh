# shellcheck shell=bash
# build-kernel.sh: plan output + patch-only application gate — sourced by run-tests.sh.
# Black-box CLI tests: no network, no real kernel build. Fixtures under
# tests/fixtures are inputs only — the script must copy the tree before patching,
# so every test pins that the fixture dir is left untouched.

SCRIPT="$PWD/scripts/build-kernel.sh"
UPSTREAM=7.0.0-38.38~24.04.4

plan() {  # <series> — print the real-mode plan for a series (--print-plan)
  "$SCRIPT" --series "$1" --upstream "$UPSTREAM" --n 2 --print-plan
}
build() {  # <patches-dir> — run the patch-only gate against the mini-tree fixture
  "$SCRIPT" --series noble --upstream "$UPSTREAM" --n 2 --patch-only \
    --fake-source-tree tests/fixtures/mini-tree --patches-dir "$1"
}

fixture_tree_digest() {  # checksum of every file under tests/fixtures/mini-tree
  (cd tests/fixtures/mini-tree && find . -type f | sort | xargs md5sum | md5sum)
}

test_plan_pins_changelog_heading() {
  plan noble | grep -q "^printf '%s (7.0.0-38.38~24.04.4+halok2) noble; urgency=medium"
}

test_plan_defers_debian_dir_lookup() {
  # fixed-string match: the host grep is ugrep, which treats a mid-pattern ^
  # as an anchor where GNU grep treats it as literal — -F pins the exact
  # deferred lookup portably across both
  # shellcheck disable=SC2016 # the literal $() is the point of a -F match
  plan noble | grep -qF 'DEBIAN=$(sed -n "s/^DEBIAN=//p" ' || {
    echo "plan must print the deferred DEBIAN lookup verbatim" >&2; return 1; }
  # no eager resolution: the plan must not mention a debian.env.new read
  if plan noble | grep -q 'debian.env.new'; then
    echo "plan must not resolve DEBIAN eagerly against debian.env.new" >&2; return 1
  fi
}

test_plan_sets_kcflags_and_compiler() {
  plan noble | grep -qF "KCFLAGS='-march=znver5 -mtune=znver5'" &&
    plan noble | grep -q 'gcc=gcc-14'
}

test_plan_generic_only_with_knobs() {
  plan noble | grep -q 'binary-generic' &&
    plan noble | grep -q 'skipabi=true' &&
    plan noble | grep -q 'skipdbg=true'
}

test_plan_resolute_omits_compiler_override() {
  # resolute builds with the packaging's native gcc-15; forcing gcc-14 there
  # would be a downgrade. its plan must say so by omission.
  if plan resolute | grep -q 'gcc=gcc-14'; then
    echo "resolute plan must not override the compiler" >&2; return 1
  fi
  plan resolute | grep -q "^printf '%s (7.0.0-38.38~24.04.4+halok2) resolute; urgency=medium" || {
    echo "resolute plan must pin its own changelog heading" >&2; return 1; }
}

test_plan_pins_source_version() {
  plan noble | grep -q 'linux-hwe-7.0=7.0.0-38.38~24.04.4'
}

test_plan_parses_changelog_before_compile() {
  plan noble | grep -q 'dpkg-parsechangelog'
}

test_plan_has_no_side_effects() {
  # --print-plan must not create anything: run it from a pristine empty cwd
  local d
  d=$(mktemp -d)
  (cd "$d" && plan noble >/dev/null) || { echo "plan run failed" >&2; rm -rf "$d"; return 1; }
  if [ -n "$(ls -A "$d")" ]; then
    echo "--print-plan created files in the cwd: $(ls -A "$d")" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

test_good_patch_applies() {
  # applies at --fuzz=0, and the fixture tree itself is never mutated
  local before after
  before=$(fixture_tree_digest)
  build tests/fixtures/good-patches >/dev/null 2>&1 || {
    echo "good patch must apply at --fuzz=0" >&2; return 1; }
  after=$(fixture_tree_digest)
  [ "$before" = "$after" ] || { echo "fixture tree was mutated by --patch-only" >&2; return 1; }
}

test_fuzz_patch_hard_fails() {
  # nonzero exit AND quilt's own failure text, captured from STDOUT only.
  # quilt/patch print their diagnostics and rejects on stdout; the script's
  # die message ("patch series failed to apply...") goes to stderr, so
  # 2>/dev/null keeps this assert honest — it can only pass on quilt's real
  # output, never on our own error text. Case-sensitive: quilt prints FAILED
  # in caps on failure only.
  local d out rc=0
  # the failure keeps its tree for inspection (keep_tree=1) under the work
  # dir: pin it to this test's own TMPDIR and remove it at test end
  d=$(mktemp -d) || return 1
  out=$(TMPDIR="$d" build tests/fixtures/fuzz-patches 2>/dev/null) || rc=$?
  rm -rf "$d"
  [ "$rc" -ne 0 ] || { echo "fuzz patch must fail at --fuzz=0" >&2; return 1; }
  printf '%s' "$out" | grep -q 'FAILED'
}

test_reject_patch_hard_fails() {
  # same stdout-only, case-sensitive contract as the fuzz test
  local d out rc=0
  d=$(mktemp -d) || return 1
  out=$(TMPDIR="$d" build tests/fixtures/reject-patches 2>/dev/null) || rc=$?
  rm -rf "$d"
  [ "$rc" -ne 0 ] || { echo "reject patch must fail at --fuzz=0" >&2; return 1; }
  printf '%s' "$out" | grep -q 'FAILED'
}

test_plan_ignores_rust_by_product() {
  # linux-lib-rust-<abi>-generic is a real per-flavour binary of both kernel
  # source packages; forgetting it in the ignore case would kill every real
  # build at deb collection — after the full ~3h compile
  plan noble | grep -qF 'linux-lib-rust-*' || {
    echo "the plan must list linux-lib-rust-* among the ignored by-products" >&2; return 1; }
}

test_plan_lists_split_by_products() {
  # linux-bpf-dev and the linux-main-modules-* splits are real by-products of
  # both kernel source packages (first real builds + archive Binary lists);
  # the plan's audit view must agree with the real ignore case
  plan noble | grep -qF 'linux-bpf-dev*' && plan noble | grep -qF 'linux-main-modules-*' || {
    echo "the plan must list linux-bpf-dev* and linux-main-modules-* among the ignored by-products" >&2; return 1; }
}

test_plan_advertises_annotation_preflight() {
  # the pre-flight probes prepare-generic before the ~3h compile; the audit
  # view must show it so the plan matches real mode
  plan noble | grep -qF 'prepare-generic' && plan noble | grep -qF 'annotations' || {
    echo "the plan must advertise the annotation pre-flight phase" >&2; return 1; }
}

test_patch_only_without_version_args() {
  # fixture mode never touches the changelog, so --upstream/--n must be optional
  "$SCRIPT" --series noble --patch-only --fake-source-tree tests/fixtures/mini-tree \
    --patches-dir tests/fixtures/good-patches >/dev/null 2>&1 || {
    echo "fixture patch-only must work without --upstream/--n" >&2; return 1; }
}
