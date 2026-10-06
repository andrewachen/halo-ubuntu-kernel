# shellcheck shell=bash
# check-leaks.sh — black-box CLI tests. Every scenario runs against an isolated
# temp GIT repo seeded with a committed copy of the gate script, so nothing
# depends on the real worktree's tracked state (the real tree tracks
# docs/superpowers/ and would hard-fail default mode). The banned-patterns file
# lives OUTSIDE the scanned tree — same shape as the real default, which sits
# inside the git dir (excluded from the scan). Covers content + pathname scans,
# exemptions, fail-closed validation, CRLF patterns and the RFC-1918 edge cases.
# No network, no mocks.

LEAK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/check-leaks.sh
CANARY='HaLo-SeCret-Canary'
CANARY_PAT='halo-secret-canary'

# new_leak_repo <dir> — fresh git repo with a committed copy of the gate script.
new_leak_repo() {
  git init -q "$1"
  git -C "$1" config user.name 'Leak Test'
  git -C "$1" config user.email 'leak@test.invalid'
  mkdir -p "$1/scripts"
  cp "$LEAK" "$1/scripts/check-leaks.sh"
  git -C "$1" add scripts/check-leaks.sh
  git -C "$1" commit -qm 'seed leak gate'
}

# A mixed-case canary must be caught (case-insensitive patterns), reported as
# file:pattern-name, and the matched content must never appear in the output.
# A comment on line 1 proves the pattern is named by its PHYSICAL line number
# (the pattern lives on line 2 -> reported as pattern-2).
test_canary_detected_reported_not_printed() {
  local d p rc=0 out
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  mkdir -p "$d/evil"
  printf '%s\n' "$CANARY" > "$d/evil/secret.txt"
  printf '# comment\n%s\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "canary run must exit 1 (got $rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  assert_eq "$out" './evil/secret.txt:pattern-2' "report is file:pattern-N with the physical line number" \
    || { rm -rf "$d" "$p"; return 1; }
  if printf '%s\n' "$out" | grep -qF "$CANARY"; then
    echo "output must not contain the private content itself:" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# A clean tree scanned with --generic (CI mode, no pattern file) exits 0. The
# tree holds a copy of the gate script AND a copy of the repo's real LICENSE and
# tests/test_leaks.sh, so this genuinely proves the published tree scans clean
# under the built-in RFC-1918 check (no false positives, no self-trips).
test_generic_clean_tree_exits_0() {
  local d rc=0
  d=$(mktemp -d)
  new_leak_repo "$d"
  cp LICENSE "$d/LICENSE"
  mkdir -p "$d/tests"
  cp tests/test_leaks.sh "$d/tests/test_leaks.sh"
  "$LEAK" --generic --root "$d" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--generic on a clean published tree must exit 0 (got $rc):" >&2
    "$LEAK" --generic --root "$d" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

# --generic flags an RFC-1918 literal by file:rfc1918, without echoing it. The
# fixture address is assembled at runtime so the gate never flags its own tests.
test_generic_detects_rfc1918() {
  local d rc=0 out addr
  d=$(mktemp -d)
  new_leak_repo "$d"
  addr=$(printf '%s.%s.1.50' 192 168)
  printf 'management iface: %s\n' "$addr" > "$d/notes.txt"
  out=$("$LEAK" --generic --root "$d" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "--generic must flag an RFC-1918 address (got $rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d"; return 1
  fi
  assert_eq "$out" './notes.txt:rfc1918' "report is file:rfc1918 for the address" \
    || { rm -rf "$d"; return 1; }
  if printf '%s\n' "$out" | grep -qF "$addr"; then
    echo "--generic output must not contain the matched address:" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

# RFC-1918 10/8 needs a full dotted quad, so numbered clauses, version strings
# and addresses that merely embed the block stay clean; real quads and the
# classic prefixes are flagged.
test_rfc1918_quad_and_prefix_cases() {
  local d rc=0 out q10 qnet addr
  d=$(mktemp -d)
  new_leak_repo "$d"
  printf '10. Clause: numbered license sections are not addresses\n' > "$d/clean-num.txt"
  printf 'kernel release 6.10.3\n' > "$d/clean-ver.txt"
  printf 'iface 110.0.0.1\n' > "$d/clean-embed.txt"
  "$LEAK" --generic --root "$d" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "--generic must stay clean on 10. Clause / 6.10.3 / 110.0.0.1 (got $rc):" >&2
    "$LEAK" --generic --root "$d" >&2
    rm -rf "$d"; return 1
  fi
  q10=$(printf '%s.%s.%s.%s' 10 0 0 5)
  qnet=$(printf '%s.%s.%s.%s' 10 20 30 0)
  addr=$(printf '%s.%s.1.50' 192 168)
  printf 'node %s\n' "$q10" > "$d/flag-quad.txt"
  printf 'net %s/24\n' "$qnet" > "$d/flag-cidr.txt"
  printf 'mgmt %s\n' "$addr" > "$d/flag-classic.txt"
  out=$("$LEAK" --generic --root "$d" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "--generic must flag full quads and classic prefixes (got $rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d"; return 1
  fi
  printf '%s\n' "$out" | grep -q 'flag-quad.txt:rfc1918' || {
    echo "full 10-quad must be flagged:" >&2; printf '%s\n' "$out" >&2; rm -rf "$d"; return 1
  }
  printf '%s\n' "$out" | grep -q 'flag-cidr.txt:rfc1918' || {
    echo "10-quad with /prefix must be flagged:" >&2; printf '%s\n' "$out" >&2; rm -rf "$d"; return 1
  }
  printf '%s\n' "$out" | grep -q 'flag-classic.txt:rfc1918' || {
    echo "the classic 192/16 prefix must still be flagged:" >&2; printf '%s\n' "$out" >&2; rm -rf "$d"; return 1
  }
  if printf '%s\n' "$out" | grep -q 'clean-'; then
    echo "clean cases must not be reported:" >&2; printf '%s\n' "$out" >&2; rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

# Pathname scan (pattern-file mode): a banned string in a FILE NAME is published
# by git archive even when the contents are clean, so it is reported.
test_pathname_scan_reports_canary_in_name() {
  local d p rc=0 out name
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  name=$(printf 'note-%s.dat' "$CANARY")
  printf 'clean content\n' > "$d/$name"
  printf '%s\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -qF "./$name:pattern-1"; then
    echo "a canary in a file name must be reported (rc=$rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# Pathname scan (--generic mode): a dotted-quad address in a path is flagged.
test_generic_pathname_scan_reports_rfc1918_in_name() {
  local d rc=0 out quad name
  d=$(mktemp -d)
  new_leak_repo "$d"
  quad=$(printf '%s.%s.%s.%s' 10 20 30 40)
  name=$(printf 'server-%s.conf' "$quad")
  printf 'clean content\n' > "$d/$name"
  out=$("$LEAK" --generic --root "$d" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -qF "./$name:rfc1918"; then
    echo "--generic must flag an address in a pathname (rc=$rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d"; return 1
  fi
  rm -rf "$d"
}

# Default mode fails closed: a missing OR empty (or comment/blank-only) patterns
# file is a usage error (exit 2), never a silent pass.
test_default_mode_missing_patterns_file_exits_2() {
  local d rc=0
  d=$(mktemp -d)
  new_leak_repo "$d"
  "$LEAK" --root "$d" >/dev/null 2>"$d/err" || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "missing patterns file must exit 2 (got $rc)" >&2; cat "$d/err" >&2
    rm -rf "$d"; return 1
  fi
  grep -qi 'pattern file' "$d/err" || {
    echo "error must name the pattern-file problem:" >&2; cat "$d/err" >&2
    rm -rf "$d"; return 1
  }
  rm -rf "$d"
}

test_default_mode_empty_patterns_file_exits_2() {
  local d p rc=0
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  : > "$p/empty.txt"
  "$LEAK" --root "$d" --patterns-file "$p/empty.txt" >/dev/null 2>"$d/err1" || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "empty patterns file must exit 2 (got $rc)" >&2; cat "$d/err1" >&2
    rm -rf "$d" "$p"; return 1
  fi
  printf '# only comments\nexempt-regex: ^Signed-off-by:\n' > "$p/directives.txt"
  "$LEAK" --root "$d" --patterns-file "$p/directives.txt" >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "a patterns file with zero banned patterns must exit 2 (got $rc)" >&2
    rm -rf "$d" "$p"; return 1
  fi
  "$LEAK" --root "$d" --patterns-file "$p/does-not-exist" >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "an unreadable --patterns-file must exit 2 (got $rc)" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# An invalid pattern regex must not silently pass: pre-validation turns it into
# a usage error naming the pattern's line, even on a tree that would otherwise
# be clean.
test_invalid_pattern_fails_closed() {
  local d p rc=0
  d=$(mktemp -d); p=$(mktemp -d)
  mkdir -p "$d/evil"
  printf '%s\n' "$CANARY" > "$d/evil/secret.txt"
  printf '%s\n' '[' "$CANARY_PAT" > "$p/bad.txt"
  "$LEAK" --root "$d" --patterns-file "$p/bad.txt" >/dev/null 2>"$d/err" || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "an invalid pattern regex must exit 2 (got $rc):" >&2; cat "$d/err" >&2
    rm -rf "$d" "$p"; return 1
  fi
  grep -q 'line 1' "$d/err" || {
    echo "invalid-pattern error must name the pattern's line number:" >&2; cat "$d/err" >&2
    rm -rf "$d" "$p"; return 1
  }
  printf '%s\n' 'a(' "$CANARY_PAT" > "$p/bad2.txt"
  "$LEAK" --root "$d" --patterns-file "$p/bad2.txt" >/dev/null 2>/dev/null || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "an unbalanced-paren pattern must exit 2 (got $rc)" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# CRLF-terminated patterns files must still match: the trailing CR is stripped.
test_crlf_pattern_file_still_detects() {
  local d p rc=0 out
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  mkdir -p "$d/evil"
  printf '%s\n' "$CANARY" > "$d/evil/secret.txt"
  printf '%s\r\n' "$CANARY_PAT" > "$p/crlf.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/crlf.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'evil/secret.txt:pattern-1'; then
    echo "a CRLF patterns file must still detect the canary (rc=$rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# Default mode hard-fails on tracked docs/superpowers/ (private spec + plan) but
# --generic skips that check.
test_default_mode_fails_tracked_docs_generic_skips() {
  local d p rc=0 out
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  mkdir -p "$d/docs/superpowers/plans"
  printf 'internal plan text\n' > "$d/docs/superpowers/plans/p.md"
  git -C "$d" add docs/superpowers/plans/p.md
  git -C "$d" commit -qm 'add private plan'
  printf '%s\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "default mode must hard-fail on tracked docs/superpowers (got $rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  printf '%s\n' "$out" | grep -q 'docs/superpowers' || {
    echo "error must name docs/superpowers:" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  }
  printf '%s\n' "$out" | grep -q '1 tracked' || {
    echo "error must list the tracked count:" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  }
  "$LEAK" --generic --root "$d" >/dev/null 2>&1 || {
    echo "--generic must skip the docs/superpowers check on the same tree" >&2
    rm -rf "$d" "$p"; return 1
  }
  rm -rf "$d" "$p"
}

# --root scans the given tree from any cwd; the default root is the invocation
# cwd (not the script's own location).
test_root_scans_given_tree_and_default_root_is_cwd() {
  local d p other cwd clean rc=0 out
  d=$(mktemp -d); p=$(mktemp -d); other=$(mktemp -d); cwd=$(mktemp -d); clean=$(mktemp -d)
  new_leak_repo "$d"
  mkdir -p "$d/evil"
  printf '%s\n' "$CANARY" > "$d/evil/secret.txt"
  printf '%s\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$(cd "$other" && "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'evil/secret.txt:pattern-1'; then
    echo "--root must scan the given tree from a different cwd (rc=$rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p" "$other" "$cwd" "$clean"; return 1
  fi
  # default root = invocation cwd: a canary planted in the cwd is found there
  mkdir -p "$cwd/evil"
  printf '%s\n' "$CANARY" > "$cwd/evil/cwd-canary.txt"
  out=$(cd "$cwd" && "$LEAK" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'evil/cwd-canary.txt:pattern-1'; then
    echo "default root must be the invocation cwd, not the script's dir (rc=$rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p" "$other" "$cwd" "$clean"; return 1
  fi
  # ...and a clean default-root cwd exits cleanly with a pattern file supplied
  ( cd "$clean" && "$LEAK" --patterns-file "$p/patterns.txt" >/dev/null 2>&1 ) || {
    echo "default root in a clean unrelated cwd must exit 0" >&2
    rm -rf "$d" "$p" "$other" "$cwd" "$clean"; return 1
  }
  rm -rf "$d" "$p" "$other" "$cwd" "$clean"
}

# The gate script copy in the tree must scan clean: it contains no canary, so a
# canary-pattern scan of the whole tree reports nothing.
test_gate_script_copy_scans_clean() {
  local d p rc=0
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  printf '%s\n' "$CANARY_PAT" > "$p/patterns.txt"
  "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "gate script copy must scan clean under a canary pattern (got $rc)" >&2
    "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# Exempt-regex directives: a file whose only canary line is an upstream-style
# Signed-off-by trailer is accepted (line-level exemption, case-sensitive).
test_exempt_signed_off_by_only_exits_0() {
  local d p rc=0
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  printf 'Signed-off-by: Someone <%s@example.net>\n' "$CANARY" > "$d/upstream.patch"
  printf '%s\nexempt-regex: ^Signed-off-by:\n' "$CANARY_PAT" > "$p/patterns.txt"
  "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "a canary only inside an exempt Signed-off-by line must pass (got $rc):" >&2
    "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# The same canary on a NON-trailer line is still reported.
test_exempt_does_not_cover_plain_lines() {
  local d p rc=0 out
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  printf 'contact: %s\n' "$CANARY" > "$d/notes.txt"
  printf '%s\nexempt-regex: ^Signed-off-by:\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'notes.txt:pattern-1'; then
    echo "a non-exempt canary line must still be reported (rc=$rc):" >&2; printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# Exemption is line-level, not file-level: exempt + non-exempt hits in the same
# file still report it.
test_exempt_is_line_level_not_file_level() {
  local d p rc=0 out
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  printf 'Signed-off-by: Someone <%s@example.net>\nplain %s\n' "$CANARY" "$CANARY" > "$d/mixed.txt"
  printf '%s\nexempt-regex: ^Signed-off-by:\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'mixed.txt:pattern-1'; then
    echo "a file with both exempt and non-exempt hits must still be reported (rc=$rc):" >&2
    printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# The exempt match is case-sensitive: a lowercase "signed-off-by" line is not
# exempted by "^Signed-off-by:" and is still reported.
test_exempt_is_case_sensitive() {
  local d p rc=0 out
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  printf 'signed-off-by: Someone <%s@example.net>\n' "$CANARY" > "$d/lower.patch"
  printf '%s\nexempt-regex: ^Signed-off-by:\n' "$CANARY_PAT" > "$p/patterns.txt"
  out=$("$LEAK" --root "$d" --patterns-file "$p/patterns.txt" 2>&1) || rc=$?
  if [ "$rc" -ne 1 ] || ! printf '%s\n' "$out" | grep -q 'lower.patch:pattern-1'; then
    echo "lowercase exempt candidates are NOT exempted by a case-sensitive regex (rc=$rc):" >&2
    printf '%s\n' "$out" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# Multiple exempt-regex directives accumulate: a second exempt covering a
# different line class is honored, not just the first.
test_exempt_directives_accumulate() {
  local d p rc=0
  d=$(mktemp -d); p=$(mktemp -d)
  new_leak_repo "$d"
  printf 'Signed-off-by: Someone <%s@example.net>\nFrom: Other <%s@example.net>\n' \
    "$CANARY" "$CANARY" > "$d/two.patch"
  printf '%s\n' "exempt-regex: ^Signed-off-by:" "exempt-regex: ^From: " "$CANARY_PAT" > "$p/patterns.txt"
  "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "both exempt directives must accumulate and clear both lines (got $rc):" >&2
    "$LEAK" --root "$d" --patterns-file "$p/patterns.txt" >&2
    rm -rf "$d" "$p"; return 1
  fi
  rm -rf "$d" "$p"
}

# Usage errors: unknown args and --generic combined with --patterns-file.
test_usage_errors_exit_2() {
  local rc=0
  "$LEAK" --nonsense >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "unknown argument must exit 2 (got $rc)" >&2; return 1
  fi
  rc=0
  "$LEAK" --generic --patterns-file /nonexistent >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "--generic with --patterns-file must exit 2 (got $rc)" >&2; return 1
  fi
}
