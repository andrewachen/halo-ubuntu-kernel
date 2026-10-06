# harness behavior tests — run-tests.sh must fail a file that has no test_*
# functions or whose source fails, instead of reporting it ok.
test_harness_fails_file_with_no_tests() {
  local d f
  d=$(mktemp -d)
  f="$d/empty.sh"
  : > "$f"
  if tests/run-tests.sh "$f" >/dev/null 2>&1; then
    echo "run-tests.sh must fail a file with no test_* functions" >&2
    return 1
  fi
  rm -rf "$d"
}
test_harness_fails_file_whose_source_errors() {
  local d f
  d=$(mktemp -d)
  f="$d/broken.sh"
  printf '. /nonexistent/no-such-file\n' > "$f"
  if tests/run-tests.sh "$f" >/dev/null 2>&1; then
    echo "run-tests.sh must fail a file whose source errors" >&2
    return 1
  fi
  rm -rf "$d"
}
