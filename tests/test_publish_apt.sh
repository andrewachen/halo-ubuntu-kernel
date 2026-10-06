# shellcheck shell=bash
# publish-apt.sh + lib/apt-index.sh + merge-index.py: stanza generation, index
# merge, signed flat-repo Release files, and a real-apt file:// e2e — sourced by
# run-tests.sh. Real dpkg-deb, dpkg-scanpackages, gpg and apt, no network; each
# test cleans its own mktemp dirs via an EXIT trap (tests run in subshells).

# shellcheck source=scripts/lib/apt-index.sh
. scripts/lib/apt-index.sh

FIXTURE="$PWD/tests/fixtures/make-dummy-deb.sh"
PUBLISH="$PWD/scripts/publish-apt.sh"
MERGE="$PWD/scripts/merge-index.py"

set_tmp_trap() {  # <dir> — remove a test's temp dir when its subshell exits
  # shellcheck disable=SC2064  # expand NOW: the caller's local is gone by trap time
  trap "rm -rf '$1'" EXIT
}

# One throwaway signing key for the whole file, generated right here in the
# sourcing shell context: GNUPGHOME and SIGN_KEYID are exported before any
# command substitution runs, so no $(...) subshell boundary can drop the
# GNUPGHOME on the floor (verified failure mode) — every test subshell and the
# publish/e2e steps inherit them.
newkey() {  # <gnupghome> — batch-generate a key; export GNUPGHOME and SIGN_KEYID
  export GNUPGHOME="$1"
  mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME" || return 1
  gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'halo test key' default default never >/dev/null 2>&1 || return 1
  SIGN_KEYID=$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
  [ -n "$SIGN_KEYID" ] || { echo "newkey: no fingerprint generated" >&2; return 1; }
  export SIGN_KEYID
}
KEYHOME=$(mktemp -d) || exit 1
newkey "$KEYHOME" || { echo "test key generation failed" >&2; exit 1; }
# the gpg agent outlives its GNUPGHOME and holds the socket dir open: kill it
# BEFORE removing the home, or the rm -rf races the agent's private dir
trap 'gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$KEYHOME"' EXIT

publish() {  # <repo-dir> <deb> <asset-name> [prev-index] — quiet success wrapper
  local repo="$1" deb="$2" asset="$3" prev="${4:-}"
  if [ -n "$prev" ]; then
    "$PUBLISH" --suite noble --repo-dir "$repo" --deb "$deb" --asset-name "$asset" \
      --prev-index "$prev" >/dev/null 2>&1
  else
    "$PUBLISH" --suite noble --repo-dir "$repo" --deb "$deb" --asset-name "$asset" \
      >/dev/null 2>&1
  fi
}

apt_cmd() {  # <aptroot> <apt-get args...> — apt against an isolated aptroot
  local root="$1"; shift
  apt-get \
    -o Dir::State::Lists="$root/var/lib/apt/lists" \
    -o Dir::State::status="$root/var/lib/dpkg/status" \
    -o Dir::Cache="$root/var/cache/apt" \
    -o Dir::Etc::sourcelist="$root/etc/apt/sources.list" \
    -o Dir::Etc::sourceparts=- \
    "$@"
}

test_dummy_deb_fixture_builds_real_deb() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" fix-check 1.0 'libc6 (>= 2.0)' >/dev/null \
    || { echo "fixture must build a deb" >&2; return 1; }
  local deb="$d/fix-check_1.0_all.deb"
  [ -f "$deb" ] || { echo "fixture deb not at the documented name" >&2; return 1; }
  assert_eq "$(dpkg-deb -f "$deb" Package)" fix-check "Package" \
    || { rm -rf "$d"; return 1; }
  assert_eq "$(dpkg-deb -f "$deb" Version)" 1.0 "Version" \
    || { rm -rf "$d"; return 1; }
  assert_eq "$(dpkg-deb -f "$deb" Depends)" 'libc6 (>= 2.0)' "Depends" \
    || { rm -rf "$d"; return 1; }
}

test_stanza_keeps_depends_rewrites_filename_and_hashes() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" test-body 1.0 'libc6 (>= 2.0)' >/dev/null \
    || { echo "dummy deb build failed" >&2; return 1; }
  local stanza
  stanza=$(stanza_for_deb "$d/test-body_1.0_all.deb" test-body_1.0_all.deb) \
    || { echo "stanza_for_deb failed" >&2; return 1; }
  grep -qxF 'Package: test-body' <<<"$stanza" \
    || { echo "Package missing from stanza" >&2; return 1; }
  # the Depends line is the meta's upgrade mechanism — hand-trimming drops it
  grep -qxF 'Depends: libc6 (>= 2.0)' <<<"$stanza" \
    || { echo "Depends dropped from the stanza" >&2; return 1; }
  grep -qxF 'Filename: test-body_1.0_all.deb' <<<"$stanza" \
    || { echo "Filename not rewritten to the asset name: $stanza" >&2; return 1; }
  grep -qE '^Size: [1-9][0-9]*$' <<<"$stanza" \
    || { echo "Size missing from stanza: $stanza" >&2; return 1; }
  grep -qE '^SHA256: [0-9a-f]{64}$' <<<"$stanza" \
    || { echo "SHA256 missing from stanza: $stanza" >&2; return 1; }
}

test_merge_preserves_unrelated_and_replaces_same_key() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  # fixture FILES on disk, not process substitutions — the v2 test read a
  # process substitution twice and awk died (verified failure mode)
  printf 'Package: keep-a\nVersion: 1\nDepends: left-alone\n\nPackage: both\nVersion: 1\nDepends: old\n' > "$d/existing"
  printf 'Package: both\nVersion: 1\nDepends: new\n\nPackage: new-b\nVersion: 2\n' > "$d/new1"
  printf 'Package: new-c\nVersion: 3\n' > "$d/new2"
  python3 "$MERGE" "$d/existing" "$d/new1" "$d/new2" > "$d/merged" \
    || { echo "merge-index.py failed" >&2; return 1; }
  local m="$d/merged"
  if grep -qF 'Depends: old' "$m"; then
    echo "same-key stanza was not replaced" >&2; return 1
  fi
  grep -qF 'Depends: new' "$m" || { echo "replacing stanza lost" >&2; return 1; }
  grep -qF 'Depends: left-alone' "$m" \
    || { echo "unrelated stanza not preserved" >&2; return 1; }
  grep -qxF 'Package: new-b' "$m" || { echo "appended stanza lost" >&2; return 1; }
  grep -qxF 'Package: new-c' "$m" \
    || { echo "second new file's stanza lost" >&2; return 1; }
  [ "$(grep -c '^Package:' "$m")" -eq 4 ] \
    || { echo "unexpected stanza count" >&2; return 1; }
  # stable ordering by first appearance: existing order first, then new ones
  local ka bm nb nc
  ka=$(grep -n '^Package: keep-a$' "$m" | cut -d: -f1)
  bm=$(grep -n '^Package: both$' "$m" | cut -d: -f1)
  nb=$(grep -n '^Package: new-b$' "$m" | cut -d: -f1)
  nc=$(grep -n '^Package: new-c$' "$m" | cut -d: -f1)
  [ "$ka" -lt "$bm" ] \
    || { echo "order: existing stanzas must keep their positions" >&2; return 1; }
  [ "$bm" -lt "$nb" ] \
    || { echo "order: appended stanzas must come after existing ones" >&2; return 1; }
  [ "$nb" -lt "$nc" ] \
    || { echo "order: new files must append in file order" >&2; return 1; }
}

test_publish_places_deb_under_asset_name() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" pkg-a 1.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  publish "$d/repo" "$d/pkg-a_1.0_all.deb" pkg-a_1.0_all.deb \
    || { echo "publish failed" >&2; return 1; }
  # the repo dir IS the deb store: the deb lands there under the asset name
  [ -f "$d/repo/pkg-a_1.0_all.deb" ] \
    || { echo "deb not stored under the asset name" >&2; return 1; }
  cmp -s "$d/repo/pkg-a_1.0_all.deb" "$d/pkg-a_1.0_all.deb" \
    || { echo "stored deb differs from the input deb" >&2; return 1; }
  grep -qxF 'Filename: pkg-a_1.0_all.deb' "$d/repo/Packages" \
    || { echo "index Filename is not the asset name" >&2; return 1; }
  local f
  for f in Packages Packages.gz Release Release.gpg InRelease; do
    [ -f "$d/repo/$f" ] || { echo "missing $f in the repo dir" >&2; return 1; }
  done
}

test_release_has_valid_until_and_per_line_sha256() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" pkg-a 1.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  "$FIXTURE" "$d" pkg-b 2.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  publish "$d/repo" "$d/pkg-a_1.0_all.deb" pkg-a_1.0_all.deb \
    || { echo "first publish failed" >&2; return 1; }
  publish "$d/repo" "$d/pkg-b_2.0_all.deb" pkg-b_2.0_all.deb "$d/repo/Packages" \
    || { echo "second publish failed" >&2; return 1; }
  local rel="$d/repo/Release"
  grep -qxF 'Suite: noble' "$rel" || { echo "Suite missing" >&2; return 1; }
  # Date and Valid-Until are RFC-2822; Valid-Until ~14 days out (1 h tolerance
  # for the two separate date invocations)
  local vu want got diff
  vu=$(sed -n 's/^Valid-Until: //p' "$rel")
  [ -n "$vu" ] || { echo "Valid-Until missing" >&2; return 1; }
  want=$(date -u -d '+14 days' +%s)
  got=$(date -u -d "$vu" +%s) || { echo "Valid-Until is not RFC-2822: $vu" >&2; return 1; }
  diff=$((want - got)); [ "$diff" -lt 0 ] && diff=$((-diff))
  [ "$diff" -le 3600 ] \
    || { echo "Valid-Until is not ~14 days out: $vu" >&2; return 1; }
  date -u -d "$(sed -n 's/^Date: //p' "$rel")" >/dev/null \
    || { echo "Date is not RFC-2822" >&2; return 1; }
  # one correct hash+size line per file in the repo dir
  local f want_line
  for f in Packages Packages.gz pkg-a_1.0_all.deb pkg-b_2.0_all.deb; do
    want_line=" $(sha256sum "$d/repo/$f" | cut -d' ' -f1) $(stat -c%s "$d/repo/$f") $f"
    grep -qxF "$want_line" "$rel" \
      || { echo "SHA256 entry wrong or missing for $f" >&2; return 1; }
  done
  if grep -qE '^ [0-9a-f]{64} [0-9]+ (Release|InRelease|Release\.gpg)$' "$rel"; then
    echo "Release lists a signature file in its own SHA256 section" >&2; return 1
  fi
  local nfiles=0 nlines name
  for f in "$d/repo"/*; do
    name=${f##*/}
    case "$name" in Release | InRelease | Release.gpg) continue ;; esac
    nfiles=$((nfiles + 1))
  done
  nlines=$(sed -n '/^SHA256:$/,$p' "$rel" | grep -c '^ ')
  [ "$nlines" -eq "$nfiles" ] \
    || { echo "expected $nfiles SHA256 lines, got $nlines" >&2; return 1; }
  # the clearsigned copy carries the same metadata
  grep -q '^Valid-Until: ' "$d/repo/InRelease" \
    || { echo "InRelease body lacks Valid-Until" >&2; return 1; }
}

test_inrelease_is_valid_clearsignature() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" pkg-a 1.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  publish "$d/repo" "$d/pkg-a_1.0_all.deb" pkg-a_1.0_all.deb \
    || { echo "publish failed" >&2; return 1; }
  # the keyring holds only the throwaway key, so exit 0 means OUR signature
  gpg --verify "$d/repo/InRelease" >/dev/null 2>&1 \
    || { echo "InRelease is not a valid clearsignature" >&2; return 1; }
  gpg --verify "$d/repo/Release.gpg" "$d/repo/Release" >/dev/null 2>&1 \
    || { echo "Release.gpg does not verify against Release" >&2; return 1; }
}

test_publish_fails_loudly_on_missing_input() {
  local d rc err; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" pkg-a 1.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  # --prev-index pointing at a nonexistent file: loud failure, no index written
  rc=0; err="$d/err-prev"
  "$PUBLISH" --suite noble --repo-dir "$d/repo" --deb "$d/pkg-a_1.0_all.deb" \
    --asset-name pkg-a_1.0_all.deb --prev-index "$d/no-such-Packages" \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "missing --prev-index must fail loudly" >&2; return 1; }
  grep -qF 'no-such-Packages' "$err" \
    || { echo "error must name the missing prev-index: $err" >&2; return 1; }
  [ ! -e "$d/repo/Packages" ] \
    || { echo "a failed publish must not leave an index behind" >&2; return 1; }
  # missing --deb file
  rc=0; err="$d/err-deb"
  "$PUBLISH" --suite noble --repo-dir "$d/repo2" --deb "$d/no-such.deb" \
    --asset-name x.deb >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "missing --deb must fail loudly" >&2; return 1; }
  grep -qF 'no-such.deb' "$err" \
    || { echo "error must name the missing deb" >&2; return 1; }
  # missing required arguments
  rc=0
  "$PUBLISH" --suite noble >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { echo "missing required arguments must fail" >&2; return 1; }
}

test_publish_rejects_tilde_in_asset_name() {
  # GitHub release asset names cannot contain '~': a tilde here would be
  # stored verbatim as the index's Filename: and then desync Filename vs the
  # uploaded asset. The caller must pass the GitHub-safe name — reject loudly.
  local d rc err; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" pkg-a 1.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  rc=0; err="$d/err-tilde"
  "$PUBLISH" --suite noble --repo-dir "$d/repo" --deb "$d/pkg-a_1.0_all.deb" \
    --asset-name 'pkg-a_1.0~rc1_all.deb' >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "a '~' in --asset-name must be rejected" >&2; return 1; }
  grep -qF "must not contain '~'" "$err" \
    || { echo "error must name the tilde problem: $(cat "$err")" >&2; return 1; }
  [ ! -e "$d/repo/Packages" ] \
    || { echo "a rejected asset name must not leave an index behind" >&2; return 1; }
}

test_publish_fails_without_signing_key() {
  local d rc; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  "$FIXTURE" "$d" pkg-a 1.0 >/dev/null || { echo "dummy deb build failed" >&2; return 1; }
  rc=0
  env -u SIGN_KEYID "$PUBLISH" --suite noble --repo-dir "$d/repo" \
    --deb "$d/pkg-a_1.0_all.deb" --asset-name pkg-a_1.0_all.deb \
    >/dev/null 2>"$d/err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "publish without SIGN_KEYID must fail loudly" >&2; return 1; }
  grep -q 'SIGN_KEYID' "$d/err" \
    || { echo "error must name SIGN_KEYID" >&2; return 1; }
}

test_apt_client_resolves_then_downloads() {
  local d; d=$(mktemp -d) || return 1
  set_tmp_trap "$d"
  local repo="$d/repo" out="$d/debs"
  # a TILDE-BEARING EVR, like every real noble meta version: the pinned
  # download-naming contract under test is that apt-get download names files
  # from the PACKAGE VERSION (which keeps '~'), not from the stored asset
  # name (which must be GitHub-safe, '~' renamed to '.'). A version without
  # '~' cannot catch the desync this test exists for.
  local evr='7.0.0-38.38~24.04.4+halok1'
  local target_asset="halo-kernel-target_${evr//\~/.}_all.deb"
  # a meta-like pair: the meta's Depends pins its exact target in the same repo
  "$FIXTURE" "$out" halo-kernel-target "$evr" none >/dev/null \
    || { echo "target fixture failed" >&2; return 1; }
  "$FIXTURE" "$out" halo-kernel-meta "$evr" "halo-kernel-target (= $evr)" >/dev/null \
    || { echo "meta fixture failed" >&2; return 1; }
  publish "$repo" "$out/halo-kernel-target_${evr}_all.deb" "$target_asset" \
    || { echo "target publish failed" >&2; return 1; }
  publish "$repo" "$out/halo-kernel-meta_${evr}_all.deb" \
    "halo-kernel-meta_${evr//\~/.}_all.deb" \
    "$repo/Packages" || { echo "meta publish failed" >&2; return 1; }
  # the deb is placed in the repo dir (the flat repo dir IS the deb store)
  # under the GitHub-safe ASSET name
  [ -f "$repo/$target_asset" ] \
    || { echo "target deb missing from the repo dir under its asset name" >&2; return 1; }
  # aptroot: the signed-by keyring lives UNDER it (apt does not relocate
  # absolute keyring paths across -o Dir= overrides)
  local root="$d/aptroot"
  mkdir -p "$root/etc/apt/trusted.gpg.d" "$root/var/lib/dpkg" \
    "$root/var/lib/apt/lists/partial" "$root/var/cache/apt/archives/partial" || return 1
  : > "$root/var/lib/dpkg/status"
  gpg --armor --export "$SIGN_KEYID" > "$d/pub.asc" 2>/dev/null || return 1
  gpg --dearmor -o "$root/etc/apt/trusted.gpg.d/halo-test.gpg" "$d/pub.asc" || return 1
  printf 'deb [signed-by=%s] file:%s/ /\n' \
    "$root/etc/apt/trusted.gpg.d/halo-test.gpg" "$repo" > "$root/etc/apt/sources.list"
  # core e2e assertion: a REAL apt client accepts the staged tree
  ( cd "$root" && apt_cmd "$root" update ) >"$d/update.out" 2>&1 \
    || { echo "apt-get update failed:"; cat "$d/update.out" >&2; return 1; }
  # resolution first: the meta resolves against its target in the same repo
  ( cd "$root" && apt_cmd "$root" -s install halo-kernel-meta ) >"$d/sim.out" 2>&1 \
    || { echo "apt-get -s install failed:"; cat "$d/sim.out" >&2; return 1; }
  grep -q '^Inst halo-kernel-meta ' "$d/sim.out" \
    || { echo "meta not selected for install: $d/sim.out" >&2; return 1; }
  grep -q '^Inst halo-kernel-target ' "$d/sim.out" \
    || { echo "target not pulled in by the meta" >&2; return 1; }
  # then an actual download, run with cwd INSIDE the aptroot (Dir= overrides
  # are relative-sensitive)
  ( cd "$root" && apt_cmd "$root" download halo-kernel-target ) >"$d/dl.out" 2>&1 \
    || { echo "apt-get download failed:"; cat "$d/dl.out" >&2; return 1; }
  # the landed file carries the VERSION's tilde, not the asset name's '.'
  [ -f "$root/halo-kernel-target_${evr}_all.deb" ] \
    || { echo "download did not land at the version-form name in the aptroot cwd:" \
         >&2; ls -la "$root" >&2; return 1; }
}
