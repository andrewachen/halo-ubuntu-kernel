#!/usr/bin/env bash
# publish-apt.sh — publish ONE deb into the flat apt repo dir and regenerate the
# signed index. The repo dir IS the deb store (tests and staging; the workflow
# uploads this dir's files as release assets). Per-deb step: store the deb
# under the GitHub-safe asset name, merge its stanza into Packages (same
# Package+Version replaced, unrelated stanzas preserved), gzip it, and write +
# sign the Release. The index is the source of truth for "published".
#
# usage: publish-apt.sh --suite SUITE --repo-dir DIR --deb FILE --asset-name NAME
#                       [--prev-index FILE]
#   --suite SUITE     suite stamped into Release (e.g. noble)
#   --repo-dir DIR    the flat repo directory (created if missing)
#   --deb FILE        the deb to publish (must exist)
#   --asset-name NAME filename under which the deb is stored and referenced
#                     (GitHub-safe: '~' already renamed to '.')
#   --prev-index FILE previous Packages file to merge (must exist when given)
# Requires SIGN_KEYID (and honors GNUPGHOME) for the Release signature.
set -u

usage() { sed -n '2,16p' "$0" >&2; }
die() { echo "publish-apt: $*" >&2; exit 1; }

suite='' repo_dir='' deb='' asset='' prev=''
while [ $# -gt 0 ]; do
  case "$1" in
    --suite) suite="$2"; shift 2 ;;
    --repo-dir) repo_dir="$2"; shift 2 ;;
    --deb) deb="$2"; shift 2 ;;
    --asset-name) asset="$2"; shift 2 ;;
    --prev-index) prev="$2"; shift 2 ;;
    *) echo "publish-apt: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[ -n "$suite" ] || { echo "publish-apt: --suite is required" >&2; usage; exit 2; }
[ -n "$repo_dir" ] || { echo "publish-apt: --repo-dir is required" >&2; usage; exit 2; }
[ -n "$deb" ] || { echo "publish-apt: --deb is required" >&2; usage; exit 2; }
[ -n "$asset" ] || { echo "publish-apt: --asset-name is required" >&2; usage; exit 2; }
# The asset name is stored verbatim as the index's Filename: — GitHub rejects
# '~' in release asset names, so a tilde here would desync Filename vs the
# stored asset (same failure class as the workflow's download-name bug). The
# CALLER must pass the GitHub-safe name ('~' already renamed to '.').
case "$asset" in
  */*) die "--asset-name '$asset' must not contain '/'" ;;
  *~*) die "--asset-name '$asset' must not contain '~' — pass the GitHub-safe name ('~' renamed to '.')" ;;
esac

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/lib/apt-index.sh
. "$REPO/scripts/lib/apt-index.sh" || exit 1

[ -f "$deb" ] || die "--deb '$deb' does not exist"
[ -z "$prev" ] || [ -f "$prev" ] || die "--prev-index '$prev' does not exist"

mkdir -p "$repo_dir" || die "cannot create repo dir $repo_dir"
tmp=$(mktemp -d) || die "mktemp -d failed"
trap 'rm -rf "$tmp"' EXIT

cp -f -- "$deb" "$repo_dir/$asset" || die "cannot store the deb as $repo_dir/$asset"

stanza_for_deb "$deb" "$asset" > "$tmp/stanza" \
  || die "cannot generate the Packages stanza for $deb"

# the merge reads the previous index before anything overwrites it (the
# workflow passes the repo dir's own Packages as --prev-index on re-publish)
if [ -n "$prev" ]; then
  python3 "$REPO/scripts/merge-index.py" "$prev" "$tmp/stanza" > "$tmp/Packages" \
    || die "cannot merge $prev with the new stanza"
else
  python3 "$REPO/scripts/merge-index.py" "$tmp/stanza" > "$tmp/Packages" \
    || die "cannot index the new stanza"
fi
mv "$tmp/Packages" "$repo_dir/Packages" || die "cannot install the merged Packages"
# -n: no mtime/name in the gzip header, so Packages.gz is byte-stable
gzip -9nc "$repo_dir/Packages" > "$tmp/Packages.gz" || die "cannot gzip Packages"
mv "$tmp/Packages.gz" "$repo_dir/Packages.gz" || die "cannot install Packages.gz"

write_release "$repo_dir" "$suite" || die "cannot write/sign the Release for suite $suite"
echo "publish-apt: $asset -> $repo_dir (suite $suite)" >&2
