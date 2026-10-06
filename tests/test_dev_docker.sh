# shellcheck shell=bash
# dev/test-in-docker.sh image resolution — sourced by run-tests.sh. The
# resolution logic must live in a sourced function taking the images.env
# path explicitly so tests can point it at a temp file; docker is stubbed on
# PATH (the seam is the container store, not our logic).
#
# Resolution order: dev/images.env IMAGE_<SERIES> pin (must exist locally)
# -> newest local halo-dev:<series>.<bake> tag by numeric bake number
# -> hard fail with guidance.

. dev/test-in-docker.sh

STUBDIR=$(mktemp -d)
trap 'rm -rf "$STUBDIR"' EXIT
# the harness runs test_* functions in alphabetical order, not declaration
# order, so nothing may assume another test made the stub: (re)create it if
# it is gone whenever a test is about to use it
ensure_stub() {
  [ -x "$STUBDIR/docker" ] && return 0
  mkdir -p "$STUBDIR"
  cat > "$STUBDIR/docker" <<'STUB'
#!/bin/sh
# stub docker modeling a container store: the store's contents come in
# $DOCKER_STUB_IMAGES, one "repo:tag" per line. `docker images` lists it;
# `docker image inspect <tag>` succeeds iff <tag> is an exact line in it;
# `docker run ...` records its full argv in $DOCKER_STUB_LOG and exits 0.
if [ "$1" = images ]; then
  printf '%s\n' "$DOCKER_STUB_IMAGES"
  exit 0
fi
if [ "$1 $2" = "image inspect" ]; then
  printf '%s\n' "$DOCKER_STUB_IMAGES" | grep -Fxq "$3"
  exit $?
fi
if [ "$1" = run ]; then
  printf '%s\n' "$*" >> "${DOCKER_STUB_LOG:?DOCKER_STUB_LOG unset}"
  exit 0
fi
echo "stub docker: unexpected command: $*" >&2
exit 1
STUB
  chmod +x "$STUBDIR/docker"
}

resolve_with() {  # <series> <images-env-content> <images-list> -> echoes resolution, rc from function
  local series=$1 envcontent=$2 list=$3 envfile rc out
  ensure_stub
  envfile=$(mktemp)
  [ -n "$envcontent" ] && printf '%s\n' "$envcontent" > "$envfile"
  out=$(PATH="$STUBDIR:$PATH" DOCKER_STUB_IMAGES="$list" \
    resolve_dev_image "$series" "$envfile" 2>&1); rc=$?
  rm -f "$envfile"
  # diagnostics stay on stdout so a test wrapping resolve_with in $( ) sees
  # them; the rc is the failure signal
  printf '%s' "$out"
  [ "$rc" -eq 0 ] || return "$rc"
}

test_resolution_env_pin_wins_over_local_tags() {
  local out
  out=$(resolve_with noble 'IMAGE_NOBLE=halo-dev:noble.3' \
    'halo-dev:noble.4
halo-dev:noble.3')
  assert_eq "$out" "halo-dev:noble.3" "explicit pin beats newer local tags" || return 1
}

test_resolution_picks_newest_bake_numerically() {
  local out
  out=$(resolve_with noble '' \
    'halo-dev:noble.9
halo-dev:noble.10
halo-dev:noble.2')
  assert_eq "$out" "halo-dev:noble.10" "numeric sort: .10 beats .9" || return 1
}

test_resolution_ignores_other_series_tags() {
  local out
  out=$(resolve_with resolute '' \
    'halo-dev:noble.10
halo-dev:resolute.1')
  assert_eq "$out" "halo-dev:resolute.1" "only the requested series' tags match" || return 1
}

test_resolution_rejects_unpinned_missing_tag() {
  local rc out
  out=$(resolve_with noble '' 'halo-dev:resolute.1'); rc=$?
  assert_eq "$rc" "1" "no pin and no matching tag -> rc 1" || return 1
  case "$out" in
    *dev/images.env*) : ;;
    *) echo "failure must point at dev/images.env guidance, got [$out]"; return 1 ;;
  esac
}

test_resolution_env_pin_must_exist_locally() {
  # a pin naming an image the container store does not have is a typo guard,
  # not a silent fallback to discovery
  local rc out
  out=$(resolve_with noble 'IMAGE_NOBLE=halo-dev:noble.3' \
    'halo-dev:noble.4'); rc=$?
  assert_eq "$rc" "1" "pinned image absent from store -> rc 1" || return 1
}

test_resolution_crlf_env_pin_is_stripped() {
  # a dev/images.env edited with CRLF line endings must not invent a phantom
  # tag ending in a carriage return: the CR is stripped before use
  local out
  out=$(resolve_with noble $'IMAGE_NOBLE=halo-dev:noble.3\r' \
    'halo-dev:noble.3')
  assert_eq "$out" "halo-dev:noble.3" "CRLF pin resolves to the real tag" || return 1
}

test_sourcing_leaves_shell_options_untouched() {
  # the old bug class: a top-level `set -u` in the script leaked into every
  # sourcing caller (including this suite). Sourcing must change nothing.
  local opts_after
  opts_after=$(bash -c 'set -e; . dev/test-in-docker.sh; echo "$-"')
  case "$opts_after" in
    *e*) : ;;
    *) echo "sourcing enabled errexit: [$opts_after]"; return 1 ;;
  esac
  case "$opts_after" in
    *u*) echo "sourcing enabled nounset: [$opts_after]"; return 1 ;;
  esac
}

test_resolution_missing_docker_binary_fails() {
  # with no docker on PATH the failure must be our guidance message, not the
  # caller's raw "command not found"; the PATH here carries the tools the
  # resolver itself needs (sed/sort/grep/head) but no docker
  local rc out envfile pathdir tool
  pathdir=$(mktemp -d)
  for tool in sed sort grep head; do ln -s "$(command -v "$tool")" "$pathdir/$tool"; done
  envfile=$(mktemp)
  printf 'IMAGE_NOBLE=halo-dev:noble.3\n' > "$envfile"
  out=$(PATH="$pathdir" resolve_dev_image noble "$envfile" 2>&1); rc=$?
  rm -rf "$pathdir" "$envfile"
  assert_eq "$rc" "1" "missing docker binary -> rc 1" || return 1
  case "$out" in
    *"docker is not available"*) : ;;
    *) echo "failure must name the missing docker, got [$out]"; return 1 ;;
  esac
}

# --- end-to-end: the real script driven by the stub docker -------------------
# These run the script itself (not the sourced function), so arg parsing,
# --print-image, usage on bad args, and the docker run argv are covered.

test_e2e_print_image_resolves_via_stub() {
  ensure_stub
  local out
  out=$(PATH="$STUBDIR:$PATH" DOCKER_STUB_IMAGES='halo-dev:noble.4' \
    dev/test-in-docker.sh --print-image noble)
  assert_eq "$out" "halo-dev:noble.4" "e2e --print-image resolves" || return 1
}

test_e2e_unknown_arg_prints_usage_and_dies() {
  ensure_stub
  local out rc
  out=$(PATH="$STUBDIR:$PATH" DOCKER_STUB_IMAGES='' \
    dev/test-in-docker.sh bogus 2>&1); rc=$?
  assert_eq "$rc" "1" "unknown argument dies rc 1" || return 1
  grep -qF "unknown argument 'bogus'" <<<"$out" || {
    echo "must name the bad argument, got: $out" >&2; return 1; }
  grep -qF 'usage: dev/test-in-docker.sh' <<<"$out" || {
    echo "must print the usage block, got: $out" >&2; return 1; }
}

test_e2e_docker_run_invocation_argv() {
  ensure_stub
  local log argv rc
  log=$(mktemp)
  PATH="$STUBDIR:$PATH" DOCKER_STUB_IMAGES='halo-dev:noble.4' \
    DOCKER_STUB_LOG="$log" dev/test-in-docker.sh noble; rc=$?
  assert_eq "$rc" "0" "stubbed docker run exits 0" || { rm -f "$log"; return 1; }
  argv=$(cat "$log"); rm -f "$log"
  grep -qF -- "--user $(id -u):$(id -g)" <<<"$argv" || {
    echo "must run as the invoking user, got: $argv" >&2; return 1; }
  grep -qF ':ro' <<<"$argv" || {
    echo "repo mount must be read-only, got: $argv" >&2; return 1; }
  grep -qF -- '-w /repo' <<<"$argv" || {
    echo "workdir must be /repo, got: $argv" >&2; return 1; }
  grep -qF -- '-e HOME=/tmp' <<<"$argv" || {
    echo "HOME must be redirected to /tmp, got: $argv" >&2; return 1; }
  case "$argv" in
    *" make test") : ;;
    *) echo "must end in 'make test', got: $argv" >&2; return 1 ;;
  esac
}
