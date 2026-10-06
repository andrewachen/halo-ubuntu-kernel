#!/usr/bin/env bash
# check-leaks.sh — one gate before anything is published: the repo must contain
# nothing that identifies the author's private infrastructure or employer.
#
# Banned patterns are themselves private, so they are never committed: default
# mode reads one grep -E regex per line from the repo's git dir (resolved via
# rev-parse --git-common-dir so a linked worktree shares the main repo's untracked
# patterns file; default path info/leak-patterns there) and fails closed if that
# file is missing or has no patterns. --generic mode runs CI-safe, non-identifying
# checks only: the RFC-1918 private IPv4 prefixes (10/8, 172.16/12, 192.168/16).
#
# Patterns file format: lines starting with '#' are comments; lines starting
# with 'exempt-regex:' add a line-level exemption (upstream Signed-off-by
# trailers are public mailing-list text and can collide with an employer-name
# pattern); every other non-empty line is a banned pattern, matched
# case-insensitively. The exempt ERE is whitespace-trimmed, and either CR or LF
# line endings are tolerated. A file is reported only when a matching line is
# NOT covered by any exempt-regex (the exempt match is case-sensitive raw text).
#
# Default mode also hard-fails when the tree is a git repo tracking files
# under docs/superpowers/ — the private spec and plan docs must never be
# published. --generic skips that check (CI and pre-squash runs).
#
# Reports go to stderr as file:pattern-name only, never the matched content:
# --generic names its built-in check rfc1918; pattern-file mode names each
# pattern by its physical line number in the patterns file (pattern-N), so a
# private regex never escapes into output. Pathnames are reported as-is — a
# banned string in a file or directory NAME is published by git archive even
# when the file's contents are clean, and the name is what must be renamed.
#
# usage: check-leaks.sh [--generic] [--root DIR] [--patterns-file FILE]
#   --generic          built-in RFC-1918 checks only (CI mode, no pattern file)
#   --root DIR         scan DIR instead of the invocation cwd (default: .)
#   --patterns-file FILE   banned-pattern file, default mode only
#   --help             print this text
#
# exit: 0 clean; 1 leak found (or tracked docs/superpowers in default mode);
#       2 usage error.
set -u

usage() { sed -n '2,38p' "$0" >&2; }

mode=default
root='.'
patterns_file=''
while [ $# -gt 0 ]; do
  case "$1" in
    --generic) mode=generic; shift ;;
    --root) [ $# -ge 2 ] || { echo "check-leaks: --root needs a directory" >&2; usage; exit 2; }
            root="$2"; shift 2 ;;
    --patterns-file) [ $# -ge 2 ] || { echo "check-leaks: --patterns-file needs a path" >&2; usage; exit 2; }
                     patterns_file="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "check-leaks: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -d "$root" ] || { echo "check-leaks: not a directory: $root" >&2; exit 2; }
if [ "$mode" = generic ] && [ -n "$patterns_file" ]; then
  echo "check-leaks: --patterns-file applies to default mode only" >&2; usage; exit 2
fi
# Resolve root to an absolute path once; the scan, the patterns-file default and
# every git call operate on it, independent of the invocation cwd.
root=$(cd "$root" && pwd) || { echo "check-leaks: cannot resolve $root" >&2; exit 2; }

# Load banned patterns + exemptions (default mode only). Patterns are stored as
# "lineno<TAB>regex" so the report can name each by its physical line number.
banned=()
exempts=()
if [ "$mode" = default ]; then
  if [ -z "$patterns_file" ]; then
    # Worktree-safe default: in a linked worktree .git is a gitfile, not a
    # directory, so resolve the shared git dir by asking git instead of taking
    # $root/.git literally. Not a git work tree -> fail closed.
    common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || {
      echo "check-leaks: $root is not a git work tree; cannot locate the default patterns file" >&2
      echo "check-leaks: pass --patterns-file, or use --generic for CI-only checks" >&2
      exit 2
    }
    case "$common" in
      /*) ;;
      *) common="$root/$common" ;;
    esac
    patterns_file="$common/info/leak-patterns"
  fi
  [ -r "$patterns_file" ] || {
    echo "check-leaks: no readable pattern file: $patterns_file" >&2
    echo "check-leaks: default mode fails closed without patterns; use --generic for CI-only checks" >&2
    exit 2
  }
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line=${line%$'\r'}                  # tolerate CRLF-terminated patterns files
    case "$line" in
      '#'*) continue ;;
      exempt-regex:*)
        er=${line#exempt-regex:}
        er=${er#"${er%%[![:space:]]*}"}   # the ERE is the value after the colon; trim
        er=${er%"${er##*[![:space:]]}"}   # surrounding whitespace so "exempt-regex: ^x" works
        if [ -n "$er" ]; then
          exempts+=("$er")
        else
          echo "check-leaks: empty exempt-regex on line $n of $patterns_file" >&2
          exit 2
        fi
        ;;
      '') continue ;;
      *) banned+=("$n"$'\t'"$line") ;;
    esac
  done < "$patterns_file"
  if [ ${#banned[@]} -eq 0 ]; then
    echo "check-leaks: pattern file has no patterns: $patterns_file" >&2
    exit 2
  fi
  # Fail closed on regexes grep cannot compile: an invalid pattern would make
  # the scan grep exit 2 with no filenames and the gate would cleanly pass.
  for entry in "${banned[@]}"; do
    pat=${entry#*$'\t'}
    grep -Eq -- "$pat" </dev/null 2>/dev/null
    rc=$?
    if [ "$rc" -eq 2 ] || [ "$rc" -ge 121 ]; then
      lineno=${entry%%$'\t'*}
      echo "check-leaks: invalid pattern on line $lineno of $patterns_file (grep exit $rc)" >&2
      exit 2
    fi
  done
  for er in "${exempts[@]}"; do
    grep -Eq -- "$er" </dev/null 2>/dev/null
    rc=$?
    if [ "$rc" -eq 2 ] || [ "$rc" -ge 121 ]; then
      echo "check-leaks: invalid exempt-regex in $patterns_file (grep exit $rc)" >&2
      exit 2
    fi
  done
fi

# A file is reportable only if at least one of its matching lines is not
# covered by any exempt-regex (exempt match is case-sensitive, raw line text).
file_has_non_exempt() {
  local f="$1" pat="$2" m content er exempted
  while IFS= read -r m; do
    content=${m#*:}
    exempted=0
    for er in "${exempts[@]}"; do
      if printf '%s\n' "$content" | grep -Eq -- "$er"; then exempted=1; break; fi
    done
    [ "$exempted" -eq 0 ] && return 0
  done < <(grep -Ein -- "$pat" "$f")
  return 1
}

# Scan one pattern over the tree (run inside the cd'd subshell): a NUL-safe
# content scan followed by a NUL-safe pathname scan — a banned string in a file
# or directory name is published by git archive even when the contents are
# clean, and the name is the identifying datum. A scan grep that errors (exit 2,
# vs 1 = no match) is a hard failure, not a clean pass.
scan_pattern() {
  local pat="$1" name="$2" rc=0 f path scanfile
  local -A flagged=()
  scanfile=$(mktemp) || { echo "check-leaks: cannot create a temp file" >&2; exit 2; }
  grep -rIilZ -E --exclude-dir=.git -- "$pat" . >"$scanfile" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 2 ] || [ "$rc" -ge 121 ]; then
    echo "check-leaks: content scan failed for $name in $root (grep exit $rc)" >&2
    rm -f "$scanfile"; exit 2
  fi
  if [ "$rc" -eq 0 ]; then
    while IFS= read -r -d '' f; do
      if [ ${#exempts[@]} -eq 0 ] || file_has_non_exempt "$f" "$pat"; then
        printf '%s:%s\n' "$f" "$name" >&2
        flagged[$f]=1
        leaks=1
      fi
    done < "$scanfile"
  fi
  find . -name .git -prune -o -print0 >"$scanfile" 2>/dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "check-leaks: pathname scan failed in $root (find exit $rc)" >&2
    rm -f "$scanfile"; exit 2
  fi
  while IFS= read -r -d '' path; do
    if [ -z "${flagged[$path]+x}" ] && printf '%s\n' "$path" | grep -Eiq -- "$pat"; then
      printf '%s:%s\n' "$path" "$name" >&2
      leaks=1
    fi
  done < "$scanfile"
  rm -f "$scanfile"
}

leaks=0
(
  cd "$root" || exit 2
  if [ "$mode" = generic ]; then
    # RFC-1918 detection: 192.168 and 172.16-31 prefixes are word-bounded by a
    # non-digit; the 10/8 block requires a full dotted quad so numbered license
    # clauses ("10. If you ..."), version strings ("6.10.3") and an address that
    # merely embeds the block (110.0.0.1) stay clean.
    regex='(^|[^0-9])(192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)|(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    scan_pattern "$regex" rfc1918
  else
    for entry in "${banned[@]}"; do
      lineno=${entry%%$'\t'*}; pat=${entry#*$'\t'}
      scan_pattern "$pat" "pattern-$lineno"
    done
  fi
  exit "$leaks"
)
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# Default mode only: the private spec + plan docs must never be published. A
# non-git tree (e.g. a git-archive export) has nothing git-tracked to check;
# any OTHER git failure is fail-closed, not "nothing tracked".
if [ "$mode" = default ]; then
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    docs=$(git -C "$root" ls-files docs/superpowers 2>/dev/null) || {
      echo "check-leaks: git ls-files failed in $root" >&2
      exit 2
    }
    if [ -n "$docs" ]; then
      count=$(printf '%s\n' "$docs" | wc -l)
      printf 'check-leaks: %d tracked file(s) under docs/superpowers must never be published\n' "$count" >&2
      exit 1
    fi
  fi
fi
exit 0
