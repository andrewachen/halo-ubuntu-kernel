#!/usr/bin/env bash
# check-upstream-helper.sh — print the newest showsrc output for a series.
# Used by the workflow's check job (and nothing else): the job captures stdout
# as --apt-output for check-upstream.sh. Runs apt-get in an isolated state dir,
# so no root is needed.
# usage: check-upstream-helper.sh <series>
set -u

[ $# -eq 1 ] || { echo "usage: check-upstream-helper.sh <series>" >&2; exit 2; }
SERIES="$1"

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/lib/apt-src.sh
. "$REPO/scripts/lib/apt-src.sh"

# shellcheck disable=SC1090 # series path is a runtime arg, not resolvable statically
. "$REPO/series/$SERIES/series.env" || {
  echo "check-upstream-helper: no series definition at series/$SERIES/series.env" >&2
  exit 1
}

wd=$(mktemp -d)
if ! apt_src_update "$SERIES" "$wd"; then
  echo "check-upstream-helper: apt_src_update failed for series '$SERIES'" >&2
  rm -rf "$wd"
  exit 1
fi
if ! apt_src_showsrc "$SERIES" "$wd" "$SOURCE_PKG"; then
  echo "check-upstream-helper: apt_src_showsrc failed for series '$SERIES'" >&2
  rm -rf "$wd"
  exit 1
fi
rm -rf "$wd"
