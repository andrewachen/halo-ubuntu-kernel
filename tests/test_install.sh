# shellcheck shell=bash
# install.sh — static safety-property tests over the installer's TEXT plus
# behavioral tests of its pure functions: the check_simulation removal gate
# (fed synthetic apt-get -s output), the dpkg status filter (fed synthetic
# dpkg-query output) and the verify_key identity gate (fed a real dearmored
# keyring). The installer's real effects need root + network, so the text
# assertions verify the structural safety ordering that running it would
# enforce. Nothing here runs install.sh as a program; only the pure functions
# are executed, in the test's own subshell.
# shellcheck disable=SC2016

SCRIPT="$PWD/box/install.sh"
PRIMARY_FPR='9ADF54E73FF6D52E6165A4F6397268D545C7794B'
ENC_FPR='02A42D21EB511FB51D380F65B888D02E6D1282D7'
SIGN_SUBKEY='65ED20E95E7D7DDAD55F76C390DFA288EBF76411'

# line_of <pattern> — first line number in the script where the literal occurs.
line_of() {
  grep -nF "$1" "$SCRIPT" | head -1 | cut -d: -f1
}

test_install_script_is_valid_bash() {
  bash -n "$SCRIPT" || {
    echo "install.sh must parse cleanly (bash -n)" >&2; return 1; }
}

test_install_requires_root_by_id_u() {
  # non-root refusal: exit 1 plus a message; implemented via id -u, so the
  # refusal is behaviorally real, not a comment
  grep -qF 'id -u' "$SCRIPT" || {
    echo "root check must use id -u" >&2; return 1; }
  grep -qiF 'must run as root' "$SCRIPT" || {
    echo "non-root refusal must carry a clear message" >&2; return 1; }
}

test_install_is_noninteractive() {
  # the curl | bash -s -- form leaves apt-get's stdin as the drained pipe,
  # so a [Y/n] prompt reads EOF and aborts mid-install ("Abort."). Two
  # prompts must be silenced: apt-get's own confirmation (-y) and dpkg's
  # debconf phase — removing the same-ABI stock kernel makes the stock
  # image's prerm ask "Abort kernel removal?" via linux-check-removal,
  # which only proceeds unattended under DEBIAN_FRONTEND=noninteractive.
  # The simulation gate is what guards safety, not the human at the prompt.
  grep -qF 'DEBIAN_FRONTEND=noninteractive apt-get install -y ' "$SCRIPT" || {
    echo "the real install must run with -y AND DEBIAN_FRONTEND=noninteractive" >&2; return 1; }
  grep -qF 'apt-get install "linux' "$SCRIPT" && {
    echo "an apt-get install without -y still present" >&2; return 1; }
  return 0
}

test_install_runs_when_piped_via_stdin() {
  # the README's curl | bash -s -- form reads the script from stdin, where
  # BASH_SOURCE is unset and ${BASH_SOURCE[0]} explodes under set -u before
  # main ever runs. A stdin execution must reach main: without --series it
  # fails the series requirement (root is not needed to get that far), and
  # the old failure shape (unbound BASH_SOURCE) is pinned as a regression.
  # usage must work in stdin mode too ($0 is "bash" there, so usage cannot
  # sed its own file): --help must print it and exit 0.
  local out rc help_out help_rc
  out=$(bash < "$SCRIPT" 2>&1); rc=$?
  case "$out" in
    *BASH_SOURCE*) echo "stdin run must not die on BASH_SOURCE: $out" >&2; return 1 ;;
  esac
  assert_eq "$rc" "2" "stdin execution reaches main (series-required refusal)" || return 1
  grep -qF 'noble or resolute' <<<"$out" || {
    echo "stdin run must show the series-required refusal, got: $out" >&2; return 1; }
  help_out=$(bash -s -- --help < "$SCRIPT" 2>&1); help_rc=$?
  assert_eq "$help_rc" "0" "stdin --help exits 0" || return 1
  grep -qF 'usage: install.sh --series' <<<"$help_out" || {
    echo "stdin --help must print the usage text, got: $help_out" >&2; return 1; }
}

test_install_series_is_required_and_validated() {
  # --series is required (no default) and limited to the two supported series
  grep -qF -e '--series is required' "$SCRIPT" || {
    echo "--series must be required (no default assumed)" >&2; return 1; }
  grep -qF 'noble|resolute' "$SCRIPT" || {
    echo "series whitelist must be noble|resolute" >&2; return 1; }
  grep -qF 'unknown series' "$SCRIPT" || {
    echo "unknown series must be rejected with a message" >&2; return 1; }
}

test_install_base_defaults_to_github_flat_repo() {
  grep -qF 'releases/download/apt-$series' "$SCRIPT" || {
    echo "--base must default to the GitHub flat repo for the series" >&2; return 1; }
}

test_install_key_fetch_is_curl_fail_loud_and_dearmor_yes() {
  grep -qF 'curl -fsSL' "$SCRIPT" || {
    echo "key fetch must use curl -fsSL (fails loudly on HTTP error)" >&2; return 1; }
  grep -qF 'command -v curl' "$SCRIPT" || {
    echo "curl availability must be checked before the fetch" >&2; return 1; }
  grep -qF 'command -v gpg' "$SCRIPT" || {
    echo "gpg availability must be checked (minimal/container Ubuntu lacks gnupg)" >&2; return 1; }
  grep -qF 'apt-get install -y gnupg' "$SCRIPT" || {
    echo "the missing-gpg message must be actionable (install gnupg)" >&2; return 1; }
  grep -qF 'gpg --dearmor --yes -o' "$SCRIPT" || {
    echo "key dearmor must carry --yes (idempotent re-runs)" >&2; return 1; }
  # dearmor to a TEMP path, verify there, then atomically install the keyring
  grep -qF 'install -m 0644' "$SCRIPT" || {
    echo "the verified key must be installed with a fixed 0644 mode" >&2; return 1; }
  grep -qF 'mv -f "$KEYRING.tmp" "$KEYRING"' "$SCRIPT" || {
    echo "the verified key must be atomically installed via mv" >&2; return 1; }
}

test_install_pins_all_three_fingerprints_and_strict_identity() {
  # all three fingerprints of the published key are pinned as literals — public
  # data mirroring keys/repo-public-key.asc
  grep -qxF "KEY_PRIMARY=$PRIMARY_FPR" "$SCRIPT" || {
    echo "the primary fingerprint literal must be pinned" >&2; return 1; }
  grep -qxF "KEY_ENC=$ENC_FPR" "$SCRIPT" || {
    echo "the encryption-subkey fingerprint literal must be pinned" >&2; return 1; }
  grep -qxF "KEY_SIGN=$SIGN_SUBKEY" "$SCRIPT" || {
    echo "the signing-subkey fingerprint literal must be pinned" >&2; return 1; }
  # strict identity, not presence: exactly one pub: and exactly the three fprs
  grep -qF 'verify_key' "$SCRIPT" || {
    echo "a strict verify_key identity check must exist" >&2; return 1; }
  grep -qF 'gpg --show-keys --with-colons' "$SCRIPT" || {
    echo "the identity check must use gpg --show-keys --with-colons" >&2; return 1; }
  grep -qF '/^pub:/ {p++} /^fpr:/ {f++} END {print p+0, f+0}' "$SCRIPT" || {
    echo "the identity check must count pub/fpr records exactly" >&2; return 1; }
  # every expected fingerprint must be required to be present
  grep -qF 'for want in "$KEY_PRIMARY" "$KEY_ENC" "$KEY_SIGN"' "$SCRIPT" || {
    echo "every pinned fingerprint must be required present" >&2; return 1; }
}

# --- behavioral: the verify_key identity gate on real keys, no mocks ---

# attacker_keyring <dir> — generate a throwaway gpg key (a real key that is
# provably NOT the published one) in a fresh GNUPGHOME under <dir> and dearmor
# its public export to <dir>/attacker.gpg. The ring is pinned to the published
# key's SAME 3-fpr shape (npub==1, nfpr==3, asserted below) so the reject tests
# reach verify_key's per-fingerprint identity loop instead of silently exiting
# at its npub/nfpr shape gate. Fresh GNUPGHOMEs for the generation and for the
# dearmor (<dir>/verify is left ready for verify_key's caller). Quiet on success.
attacker_keyring() {
  local dir="$1" fpr npub nfpr
  mkdir -p "$dir/attacker" "$dir/verify" || return 1
  chmod 700 "$dir/attacker" "$dir/verify" || return 1
  GNUPGHOME="$dir/attacker" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'attacker test key' default default never >/dev/null 2>&1 || return 1
  # default generation makes two fprs (primary + cv25519 enc subkey); give it
  # the published ring's full shape by adding the ed25519 sign subkey
  fpr=$(GNUPGHOME="$dir/attacker" gpg --batch --list-keys --with-colons 2>/dev/null \
    | awk -F: '/^fpr:/ {print $10; exit}')
  [ -n "$fpr" ] || { echo "attacker_keyring: no fingerprint generated" >&2; return 1; }
  GNUPGHOME="$dir/attacker" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$fpr" ed25519 sign 2y >/dev/null 2>&1 \
    || { echo "attacker_keyring: sign-subkey add failed" >&2; return 1; }
  # the fixture MUST have the published ring's shape (npub==1 nfpr==3), or the
  # reject tests would exit at the shape gate and never test fingerprint identity
  read -r npub nfpr <<< "$(GNUPGHOME="$dir/attacker" gpg --batch --list-keys --with-colons 2>/dev/null \
    | awk -F: '/^pub:/ {p++} /^fpr:/ {f++} END {print p+0, f+0}')"
  [ "$npub" -eq 1 ] || { echo "attacker_keyring: expected npub=1, got $npub" >&2; return 1; }
  [ "$nfpr" -eq 3 ] || { echo "attacker_keyring: expected nfpr=3, got $nfpr" >&2; return 1; }
  GNUPGHOME="$dir/attacker" gpg --armor --export >"$dir/attacker.asc" 2>/dev/null || return 1
  GNUPGHOME="$dir/verify" gpg --dearmor -o "$dir/attacker.gpg" "$dir/attacker.asc" 2>/dev/null
}

test_install_verify_key_accepts_the_published_key() {
  # shellcheck source=box/install.sh
  source "$SCRIPT"
  local d
  d=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand NOW: the local is gone by trap time
  trap "gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf '$d'" EXIT
  mkdir -p "$d/gnupg" && chmod 700 "$d/gnupg" || return 1
  # dearmor the committed key to a keyring file, exactly as the installer does
  # (curl ... | gpg --dearmor -o "$tmp/key.gpg")
  GNUPGHOME="$d/gnupg" gpg --dearmor -o "$d/keyring.gpg" "$PWD/keys/repo-public-key.asc" 2>/dev/null \
    || { echo "dearmor of the committed published key failed" >&2; return 1; }
  GNUPGHOME="$d/gnupg" verify_key "$d/keyring.gpg" \
    || { echo "verify_key must accept the committed published keyring" >&2; return 1; }
}

test_install_verify_key_rejects_an_attacker_key() {
  # shellcheck source=box/install.sh
  source "$SCRIPT"
  local d rc=0
  d=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand NOW: the local is gone by trap time
  trap "gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf '$d'" EXIT
  attacker_keyring "$d" || { echo "attacker key generation failed" >&2; return 1; }
  # the throwaway key has the published ring's SAME 3-fpr shape (asserted by
  # attacker_keyring), so it passes verify_key's npub/nfpr shape gate and this
  # rejection MUST come from the per-fingerprint identity loop: the fingerprints
  # differ. A shape-gate exit here would mean the compare never ran.
  GNUPGHOME="$d/verify" verify_key "$d/attacker.gpg" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "verify_key must reject a keyring that is not the published key" >&2; return 1; }
}

test_install_verify_key_rejects_an_extra_key_next_to_the_published_one() {
  # the threat the strict check exists for: a compromised release asset ships
  # OUR key PLUS the attacker's in one keyring. apt trusts every signing key in
  # the ring, so a mere presence check would pass here — verify_key must not.
  # shellcheck source=box/install.sh
  source "$SCRIPT"
  local d rc=0
  d=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand NOW: the local is gone by trap time
  trap "gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf '$d'" EXIT
  attacker_keyring "$d" || { echo "attacker key generation failed" >&2; return 1; }
  GNUPGHOME="$d/verify" gpg --dearmor -o "$d/published.gpg" "$PWD/keys/repo-public-key.asc" 2>/dev/null \
    || { echo "dearmor of the committed published key failed" >&2; return 1; }
  cat "$d/published.gpg" "$d/attacker.gpg" > "$d/combo.gpg"
  GNUPGHOME="$d/verify" verify_key "$d/combo.gpg" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "verify_key must reject the published key PLUS an extra key in one keyring" >&2; return 1; }
}

test_install_source_line_is_obs_flat_form() {
  # the exact flat source template: signed-by the keyring path, ending '.../ /'
  grep -qxF 'KEYRING=/usr/share/keyrings/halo-ubuntu-kernel.gpg' "$SCRIPT" || {
    echo "keyring path must be the /usr/share/keyrings file" >&2; return 1; }
  grep -qF 'deb [signed-by=%s] %s/ /' "$SCRIPT" || {
    echo "source line template must be the OBS flat form ending in the bare ' / /'" >&2; return 1; }
  # the write must go to the fixed sources.list.d path
  grep -qF 'halo-ubuntu-kernel.list' "$SCRIPT" || {
    echo "source must be written under /etc/apt/sources.list.d" >&2; return 1; }
}

test_install_pin_file_content() {
  grep -qxF 'Pin: release o=Ubuntu' "$SCRIPT" || {
    echo "pin must target release origin o=Ubuntu (covers archive + mirrors + security)" >&2; return 1; }
  grep -qxF 'Pin-Priority: 100' "$SCRIPT" || {
    echo "pin must be Pin-Priority: 100" >&2; return 1; }
  grep -qxF 'Package: linux-image* linux-modules*' "$SCRIPT" || {
    echo "pin must cover linux-image* and linux-modules*" >&2; return 1; }
}

test_install_simulation_gate_present_before_real_install() {
  grep -qF 'apt-get -s install' "$SCRIPT" || {
    echo "the install must be simulated first (apt-get -s)" >&2; return 1; }
  grep -qF 'check_simulation' "$SCRIPT" || {
    echo "the simulation output must be inspected by check_simulation" >&2; return 1; }
  grep -qF 'Remv|Purg' "$SCRIPT" || {
    echo "the gate must match both Remv and Purg removal verbs (real apt prints 'Remv', no colon)" >&2; return 1; }
  grep -qF '*firmware*|*microcode*' "$SCRIPT" || {
    echo "the gate must match firmware|microcode in removed package names" >&2; return 1; }
}

test_install_meta_install_line_present() {
  grep -qF 'apt-get install -y "linux-image-halo-$series"' "$SCRIPT" || {
    echo "the real install of the halo meta must be present" >&2; return 1; }
}

test_install_manual_marks_via_dpkg_query() {
  grep -qF 'apt-mark manual' "$SCRIPT" || {
    echo "firmware + installed kernels must be apt-mark manual" >&2; return 1; }
  grep -qF 'linux-firmware amd64-microcode intel-microcode' "$SCRIPT" || {
    echo "the three firmware/microcode packages must be named for marking" >&2; return 1; }
  # the glob must cover BOTH image name shapes: the stock signed
  # linux-image-<abi>-generic AND our linux-image-unsigned-<abi>-generic
  # ('linux-image-[0-9]*' missed the unsigned form — our own image was never
  # marked) while keeping the meta packages out
  grep -qF "dpkg-query -W -f='\${Package}\\n' 'linux-image-*[0-9]*-generic'" "$SCRIPT" || {
    echo "installed kernel images must be discovered via the both-shapes glob" >&2; return 1; }
}

test_install_status_filter_tolerates_fixed_width_abbrev() {
  # db:Status-Abbrev is FIXED-WIDTH 3 chars: an installed package reads 'ii '
  # (trailing space = empty error field). An exact 'ii' comparison selects
  # NOTHING. Both helpers must accept the real dpkg-query shapes.
  source "$SCRIPT"
  local out rc
  # the real dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' shape,
  # including the trailing space in the abbreviation field
  out=$(printf 'ii \tlinux-firmware\nrc \tlinux-image-6.8.0-45-generic\nii\tlinux-modules-7.0.0-38-generic\nhi \tlinux-half\n' \
    | select_installed) || rc=$?
  grep -qxF 'linux-firmware' <<<"$out" \
    || { echo "select_installed must select 'ii ' (trailing space): got [$out]" >&2; return 1; }
  grep -qxF 'linux-modules-7.0.0-38-generic' <<<"$out" \
    || { echo "select_installed must select 'ii' (no padding)" >&2; return 1; }
  if grep -q 'linux-image-6.8.0-45-generic\|linux-half' <<<"$out"; then
    echo "select_installed must not select rc/hi packages: got [$out]" >&2; return 1
  fi
  # the per-package abbreviation check used by mark_manual
  is_installed_status 'ii ' || { echo "'ii ' must count as installed" >&2; return 1; }
  is_installed_status 'ii'  || { echo "'ii' must count as installed" >&2; return 1; }
  for bad in 'rc ' 'un ' 'hi ' 'iiR' ''; do
    if is_installed_status "$bad"; then
      echo "status [$bad] must not count as installed" >&2; return 1
    fi
  done
}

test_install_holds_are_derived_not_hardcoded() {
  grep -qF 'apt-mark hold' "$SCRIPT" || {
    echo "stock metas must be held via apt-mark hold" >&2; return 1; }
  grep -qF "'linux-generic*' 'linux-image-generic*' 'linux-headers-generic*'" "$SCRIPT" || {
    echo "hold patterns must cover the generic meta name shapes" >&2; return 1; }
  grep -qF 'apt-mark hold "$pkg"' "$SCRIPT" || {
    echo "holds must act on each dpkg-query-derived package" >&2; return 1; }
  # nothing may be hardcoded by exact name in the hold step: reject a literal
  # 'apt-mark hold linux...' (name or quoted name); the variable form passes
  if grep -Eq 'apt-mark hold "?[a-z]' "$SCRIPT"; then
    echo "holds must be derived from dpkg-query, never hardcoded by name" >&2; return 1
  fi
}

test_install_safety_ordering_by_text() {
  # the structural safety chain is a matter of order: key identity BEFORE the
  # apt source is enabled; apt-get update, then simulate, then firmware marked
  # manual, then the real install
  local fp src upd sim fm ins
  fp=$(line_of 'gpg --show-keys --with-colons')
  src=$(line_of 'deb [signed-by=%s] %s/ /')
  upd=$(line_of 'apt-get update')
  # the executable lines only — 'apt-get -s install ...' appears in check_simulation's
  # doc comment too, so key on the code's argument form, not the bare verb
  sim=$(line_of 'apt-get -s install "linux-image-halo')
  fm=$(line_of 'linux-firmware amd64-microcode intel-microcode')
  ins=$(line_of 'apt-get install -y "linux-image-halo-$series"')
  if [ -z "$fp" ] || [ -z "$src" ] || [ -z "$upd" ] || [ -z "$sim" ] || [ -z "$fm" ] || [ -z "$ins" ]; then
    echo "ordering test could not locate every step" >&2; return 1
  fi
  [ "$fp" -lt "$src" ] || {
    echo "key identity check (line $fp) must precede the source enable (line $src)" >&2; return 1; }
  [ "$upd" -lt "$sim" ] || {
    echo "apt-get update (line $upd) must precede the simulation (line $sim)" >&2; return 1; }
  [ "$sim" -lt "$ins" ] || {
    echo "simulation gate (line $sim) must precede the real install (line $ins)" >&2; return 1; }
  [ "$fm" -lt "$ins" ] || {
    echo "firmware must be marked manual (line $fm) before the install (line $ins) — partial-failure safety" >&2; return 1; }
}

# --- behavioral: the pure simulation gate, real logic, no mocks ---

# run_check_simulation <abi> <sim-input> — the gate's stderr+exit in one call
run_check_simulation() {
  local abi="$1"; shift
  printf '%s' "$1" | check_simulation "$abi" 2>&1
}

test_check_simulation_rejects_firmware_removal() {
  # shellcheck source=box/install.sh
  source "$SCRIPT"
  local rc=0 out
  # real apt-get -s shape: 'Remv <pkg> [<ver>]' (space, no colon)
  out=$(run_check_simulation 7.0.0-38 \
    'Inst linux-image-halo-noble [7.0.0-38.38~24.04.4+halok1] (file:./amd64)
Remv linux-firmware [20240318.git3b128b60.0ubuntu3.1]
') || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "check_simulation must fail when the sim removes linux-firmware" >&2; return 1; }
  # one assertion covers both: the full simulation is reprinted AND names the package
  grep -qF 'Remv linux-firmware' <<<"$out" || {
    echo "the gate must reprint the full simulation naming linux-firmware" >&2; return 1; }
  # a config-file PURGE of a microcode package is a removal too
  rc=0
  out=$(run_check_simulation 7.0.0-38 \
    'Purg amd64-microcode [3.20250204.1]
Inst linux-image-halo-resolute [7.0.0-38.38~24.04.4+halok1] (file:./amd64)
') || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "check_simulation must fail when the sim purges amd64-microcode" >&2; return 1; }
  grep -qF 'Purg amd64-microcode' <<<"$out" || {
    echo "the gate must reprint the full simulation naming amd64-microcode" >&2; return 1; }
}

test_check_simulation_aborts_other_abi_kernel_removal() {
  # shellcheck source=box/install.sh
  source "$SCRIPT"
  local rc=0 out
  # an other-ABI stock kernel is a GRUB fallback: the sim removing it must
  # abort the install (the old gate accepted any kernel Remv)
  out=$(run_check_simulation 7.0.0-38 \
    'Inst linux-image-halo-noble [7.0.0-38.38~24.04.4+halok1]
Remv linux-image-6.8.0-45-generic [6.8.0-45-generic]
') || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "removing an other-ABI kernel image must abort" >&2; return 1; }
  grep -qF 'Remv linux-image-6.8.0-45-generic' <<<"$out" || {
    echo "the abort must name the offending removal" >&2; return 1; }
  rc=0
  run_check_simulation 7.0.0-38 \
    'Inst linux-image-halo-noble [7.0.0-38.38~24.04.4+halok1]
Purg linux-modules-6.8.0-45-generic [6.8.0-45-generic]
' >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "purging an other-ABI modules package must abort" >&2; return 1; }
}

test_check_simulation_accepts_clean_and_same_abi_removals() {
  # shellcheck source=box/install.sh
  source "$SCRIPT"
  local rc=0
  # a plain simulation with no removals at all
  run_check_simulation 7.0.0-38 \
    'Inst linux-image-halo-noble [7.0.0-38.38~24.04.4+halok1] (file:./amd64)
Conf linux-image-halo-noble
' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "a clean simulation must pass" >&2; return 1; }
  # expected removals: the same-ABI stock signed image our unsigned image
  # conflicts away, the same-ABI stock modules our build replaces, and the
  # stock metas whose dependency chain the removal breaks
  rc=0
  run_check_simulation 7.0.0-38 \
    'Inst linux-image-halo-noble [7.0.0-38.38~24.04.4+halok1]
Inst linux-image-unsigned-7.0.0-38-generic [7.0.0-38.38~24.04.4+halok1]
Remv linux-image-7.0.0-38-generic [7.0.0-38.38~24.04.4]
Remv linux-image-generic-hwe-24.04 [7.0.0-38.38~24.04.4]
Remv linux-generic-hwe-24.04 [7.0.0-38.38~24.04.4]
' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "same-ABI stock image + stock metas removals are expected and must pass" >&2; return 1; }
  rc=0
  run_check_simulation 7.0.0-38 \
    'Remv linux-modules-7.0.0-38-generic [7.0.0-38.38~24.04.4]
Remv linux-modules-extra-7.0.0-38-generic [7.0.0-38.38~24.04.4]
' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "same-ABI stock modules removals are expected and must pass" >&2; return 1; }
}

test_install_persistent_kernel_protection_hook() {
  # the persistent protection is real config, not a comment: the apt.conf.d
  # post-invoke must reference the shipped script, and the script must
  # apt-mark manual the installed kernel image/modules packages it derives
  # from dpkg-query with the fixed-width status filter
  grep -qF '/etc/apt/apt.conf.d/99-halo-keep-kernels' "$SCRIPT" || {
    echo "the hook conf path must be installed" >&2; return 1; }
  grep -qF '/usr/lib/halo-ubuntu-kernel/keep-kernels' "$SCRIPT" || {
    echo "the hook script path must be installed" >&2; return 1; }
  grep -qF 'DPkg::Post-Invoke { "/usr/lib/halo-ubuntu-kernel/keep-kernels" };' "$SCRIPT" || {
    echo "the conf must register the script as a DPkg::Post-Invoke" >&2; return 1; }
  grep -qF "chmod 0755 /usr/lib/halo-ubuntu-kernel/keep-kernels" "$SCRIPT" || {
    echo "the hook script must be executable" >&2; return 1; }
  # the script's core: derive installed kernel image/modules packages from
  # dpkg-query with the fixed-width status filter, then apt-mark manual them
  grep -qF "'linux-image-*[0-9]*-generic' 'linux-modules-*[0-9]*-generic'" "$SCRIPT" || {
    echo "the hook must query both image and modules package shapes" >&2; return 1; }
  grep -qF "awk -F'\\t' '\$1 ~ /^ii ?\$/{print \$2}'" "$SCRIPT" \
    || grep -qF "awk -F'\\t' '\$1 ~ /^ii ?\$/ {print \$2}'" "$SCRIPT" \
    || { echo "the hook must filter on the installed status abbreviation" >&2; return 1; }
  grep -qF 'apt-mark manual $pkgs' "$SCRIPT" || {
    echo "the hook must apt-mark the derived packages manual" >&2; return 1; }
  # the hook is installed AFTER the real install (it protects future upgrades)
  local ins hook
  ins=$(line_of 'apt-get install -y "linux-image-halo-$series"')
  hook=$(line_of 'DPkg::Post-Invoke')
  [ -n "$ins" ] && [ -n "$hook" ] || { echo "hook ordering test could not locate its anchors" >&2; return 1; }
  [ "$ins" -lt "$hook" ] || {
    echo "the persistent hook (line $hook) must be installed after the real install (line $ins)" >&2; return 1; }
}
