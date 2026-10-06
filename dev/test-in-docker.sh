#!/usr/bin/env bash
# dev/test-in-docker.sh — run the repo's full test suite inside a pre-baked
# halo-dev toolchain container: the local twin of CI's test job (CI runs the
# same noble container family; quilt included), for hosts that lack tooling
# the suite needs (e.g. quilt). CI is the authoritative gate.
#
# The halo-dev:<series>.<bake> images are baked OUTSIDE the repo from a
# machine-local recipe (no private material enters them), so a fresh machine
# cannot recreate them from this repo alone. Resolution:
# - dev/images.env (git-ignored) may pin IMAGE_<SERIES>=repo:tag explicitly
#   (written by the image-baking loop on the build host);
# - otherwise the newest local halo-dev:<series>.<bake> tag wins (numeric
#   bake sort, so noble.10 beats noble.9);
# - with neither, this fails and says so.
#
# Runs as the invoking user with a writable HOME, and mounts the repo
# read-only — the suite must not write into the tree.
# usage: dev/test-in-docker.sh [--print-image] [noble]
usage() { sed -n '2,18p' "$0" >&2; }
die() { echo "dev/test-in-docker.sh: $*" >&2; exit 1; }

# resolve_dev_image SERIES IMAGES_ENV — echo the container image to use for
# SERIES; rc 1 with a message on stderr when resolution fails (returns, does
# not exit: sourced callers must survive).
resolve_dev_image() {
  local series=$1 images_env=$2 var pin='' tag
  command -v docker >/dev/null 2>&1 \
    || { echo "dev/test-in-docker.sh: docker is not available — image resolution needs the local docker store" >&2; return 1; }
  var="IMAGE_$(printf '%s' "$series" | tr '[:lower:]' '[:upper:]')"
  pin=$(sed -n "s/^$var=//p" "$images_env" 2>/dev/null | head -1) || true
  pin=${pin%$'\r'}   # a CRLF-edited images.env must not invent a phantom tag
  if [ -n "$pin" ]; then
    docker image inspect "$pin" >/dev/null 2>&1 \
      || { echo "dev/test-in-docker.sh: dev/images.env pins $var=$pin but that image is not in the local docker store" >&2; return 1; }
    echo "$pin"
    return 0
  fi
  tag=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -E "^halo-dev:$series\.[0-9]+$" | sort -t. -k2 -n | tail -1) || true
  [ -n "$tag" ] \
    || { echo "dev/test-in-docker.sh: no halo-dev:$series.* image in the local docker store and no $var in dev/images.env — bake one or pin dev/images.env" >&2; return 1; }
  echo "$tag"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
  print_image=0
  series=noble
  for arg in "$@"; do
    case "$arg" in
      --print-image) print_image=1 ;;
      # noble only: the suite must match CI's test container; the resolver
      # itself stays series-generic for other dev scripts
      noble) series=$arg ;;
      *) usage; die "unknown argument '$arg'" ;;
    esac
  done
  image=$(resolve_dev_image "$series" "$REPO/dev/images.env")
  if [ "$print_image" = 1 ]; then
    echo "$image"
    exit 0
  fi
  exec docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$REPO":/repo:ro \
    -w /repo \
    -e HOME=/tmp \
    "$image" \
    make test
fi
