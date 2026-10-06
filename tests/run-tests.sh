#!/usr/bin/env bash
# runs each test file in its own bash process; the harness calls every test_*
# function defined in it and fails if any one fails. usage: run-tests.sh FILES...
set -u
assert_eq() { [ "$1" = "$2" ] || { echo "assert_eq [$3]: got [$1] want [$2]"; return 1; }; }
assert_ok() { "$@" || { echo "assert_ok: [$*] failed"; return 1; }; }
runner() {
  local f="$1" t fails=0 found=0
  for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    found=1
    if ( "$t" ); then echo "ok   $t"; else echo "FAIL $t"; fails=$((fails+1)); fi
  done
  [ "$found" -eq 1 ] || { echo "no test_* functions in $f" >&2; return 1; }
  return $fails
}
total=0
for f in "$@"; do
  if bash -c "set -e; $(declare -f assert_eq assert_ok); source '$f'; $(declare -f runner); runner '$f'" 2>&1; then
    echo "ok   $f"
  else
    echo "FAIL $f"; total=$((total+1))
  fi
done
[ "$total" -eq 0 ] || { echo "$total test file(s) failed"; exit 1; }
echo "all tests passed"
