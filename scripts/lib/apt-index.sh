# shellcheck shell=bash
# apt-index.sh — flat-repo index building blocks. Sourced; requires SIGN_KEYID
# (key id or fingerprint of the signer) and honors GNUPGHOME for signing.
# stanza_for_deb <deb> <asset-name> — print the deb's Packages stanza with
#   Filename: rewritten to exactly <asset-name> (the release-asset name; apt
#   rejects absolute-URL Filename entries, so the name must be what the client
#   fetches relative to the repo base URI)
# write_release <dir> <suite> — write <dir>/Release for the files present there
#   (RFC-2822 Date, Valid-Until 14 days out so a stale index fails loudly at
#   apt update, one SHA256 line per file) and sign it into InRelease
#   (clearsigned) and Release.gpg (detached, armored)

stanza_for_deb() {  # <deb> <asset-name>
  local deb="$1" asset="$2" tmp
  [ -f "$deb" ] || { echo "apt-index: stanza_for_deb: '$deb' is not a file" >&2; return 1; }
  case "$asset" in
    '' | */) { echo "apt-index: stanza_for_deb: bad asset name '$asset'" >&2; return 1; } ;;
  esac
  tmp=$(mktemp -d) || return 1
  # scan a symlink NAMED for the asset; the Filename: line is rewritten to the
  # bare asset name below either way
  ln -s "$(readlink -f "$deb")" "$tmp/$asset" || { rm -rf "$tmp"; return 1; }
  if ! dpkg-scanpackages "$tmp" /dev/null 2>"$tmp/scan.err" >"$tmp/stanza.raw" \
    || [ ! -s "$tmp/stanza.raw" ]; then
    echo "apt-index: dpkg-scanpackages produced no stanza for $deb:" >&2
    cat "$tmp/scan.err" >&2
    rm -rf "$tmp"
    return 1
  fi
  # rewrite Filename: to the asset name verbatim — line-by-line in bash, so no
  # sed escaping can mangle the name
  local line
  while IFS= read -r line; do
    case "$line" in
      'Filename: '*) printf 'Filename: %s\n' "$asset" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$tmp/stanza.raw"
  rm -rf "$tmp"
}

write_release() {  # <dir> <suite>
  local dir="$1" suite="$2" f name
  [ -d "$dir" ] || { echo "apt-index: write_release: '$dir' is not a directory" >&2; return 1; }
  [ -n "$suite" ] || { echo "apt-index: write_release: empty suite" >&2; return 1; }
  [ -n "${SIGN_KEYID:-}" ] \
    || { echo "apt-index: SIGN_KEYID is not set (release signing requires it)" >&2; return 1; }
  {
    printf 'Origin: halo-ubuntu-kernel\n'
    printf 'Label: halo-ubuntu-kernel\n'
    printf 'Suite: %s\n' "$suite"
    printf 'Codename: %s\n' "$suite"
    printf 'Date: %s\n' "$(date -Ru)"
    printf 'Valid-Until: %s\n' "$(date -Ru -d '+14 days')"
    printf 'Description: halo kernel packages for %s (flat repository)\n' "$suite"
    printf 'SHA256:\n'
  } > "$dir/Release" || return 1
  # one hash+size+name line per file, appended directly to the file —
  # accumulating the lines in a command substitution was a verified failure
  # mode. Release itself is excluded (self-reference); InRelease/Release.gpg
  # are signature files and are never listed inside Release.
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    case "$name" in Release | InRelease | Release.gpg) continue ;; esac
    printf ' %s %s %s\n' \
      "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$name" >> "$dir/Release" || return 1
  done
  # gpg's trustdb/setup chatter goes to a temp file: quiet on success, printed
  # on failure so a signing problem is still loud
  gerr=$(mktemp) || return 1
  if ! gpg --batch --yes --clearsign --local-user "$SIGN_KEYID" \
    --output "$dir/InRelease" "$dir/Release" 2>"$gerr"; then
    echo "apt-index: gpg clearsign of InRelease failed:" >&2
    cat "$gerr" >&2
    rm -f "$gerr"
    return 1
  fi
  if ! gpg --batch --yes --detach-sign --armor --local-user "$SIGN_KEYID" \
    --output "$dir/Release.gpg" "$dir/Release" 2>"$gerr"; then
    echo "apt-index: gpg detach-sign of Release.gpg failed:" >&2
    cat "$gerr" >&2
    rm -f "$gerr"
    return 1
  fi
  rm -f "$gerr"
}
