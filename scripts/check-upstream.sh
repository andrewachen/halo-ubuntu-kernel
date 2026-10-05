#!/usr/bin/env bash
# check-upstream.sh — decide whether a series needs a rebuild, and with which
# +halokN.
# Compares the newest upstream version in the given apt showsrc output against
# the versions already published (the published set is the source of truth, not
# GitHub Releases, so a build whose publish failed is retried). This script never
# runs apt itself; the workflow's check job gets the showsrc output from
# check-upstream-helper.sh and hands it over via --apt-output.
#
# usage: check-upstream.sh --series NAME --apt-output FILE
#        [--published-file FILE | --index FILE] [--force]
#   --apt-output       file containing apt-cache showsrc output
#   --published-file   one published version per line
#   --index            a published Packages file; its Version: lines count as published
#   --force            report changed even when the upstream version is unchanged
#
# Prints single-line JSON on stdout: {"series":...,"upstream_version":...,
# "halo_n":N,"changed":true|false} — built with printf, not jq (jq isn't
# guaranteed in the check container). Nonzero exit with a stderr message on
# missing/invalid apt output.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
usage() { sed -n '2,19p' "$0" >&2; }

series='' apt_output='' published_file='' index='' force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --series) series="$2"; shift 2 ;;
    --apt-output) apt_output="$2"; shift 2 ;;
    --published-file) published_file="$2"; shift 2 ;;
    --index) index="$2"; shift 2 ;;
    --force) force=1; shift ;;
    *) echo "check-upstream: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$series" ] || [ -z "$apt_output" ]; then
  echo "check-upstream: --series and --apt-output are required" >&2; usage; exit 2
fi
if [ -n "$published_file" ] && [ -n "$index" ]; then
  echo "check-upstream: give --published-file or --index, not both" >&2; usage; exit 2
fi

# The published set as one version per line: verbatim from --published-file (blank
# lines dropped) or the Version: line of every stanza in a Packages index.
read_published() {
  if [ -n "$published_file" ]; then
    [ -r "$published_file" ] || { echo "check-upstream: published file not readable: $published_file" >&2; return 1; }
    grep -v '^[[:space:]]*$' "$published_file" || [ $? -eq 1 ]  # 1 = no matches = empty set
  elif [ -n "$index" ]; then
    [ -r "$index" ] || { echo "check-upstream: index not readable: $index" >&2; return 1; }
    sed -n 's/^Version: //p' "$index"
  fi
}

[ -r "$apt_output" ] || { echo "check-upstream: apt output not readable: $apt_output" >&2; exit 1; }
upstream=$(newest_deb_version < "$apt_output") || {
  echo "check-upstream: no Version: lines in '$apt_output'" >&2
  exit 1
}
published=$(read_published) || exit 1

# halo_n is the next N even when unchanged (documents what the next build would use).
# $published unquoted on purpose: word-split the published set into one arg per version.
# shellcheck disable=SC2086
halo_n=$(next_halo_n "$upstream" $published)

# A published version whose stock prefix equals the upstream means the series is current.
published_same=0
# shellcheck disable=SC2086
for pv in $published; do
  [ "$(strip_halo_suffix "$pv")" = "$upstream" ] && published_same=1
done

changed=false
if [ "$published_same" -eq 0 ] || [ "$force" -eq 1 ]; then
  changed=true
fi

printf '{"series":"%s","upstream_version":"%s","halo_n":%s,"changed":%s}\n' \
  "$series" "$upstream" "$halo_n" "$changed"
