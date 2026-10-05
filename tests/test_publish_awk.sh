# shellcheck shell=bash
# build.yml publish-job awk — the pre-publish index PRUNE (drop stanzas whose
# asset never made it to the release) and the re-sign META-SELECTION are
# inlined in .github/workflows/build.yml, with no committed script to unit
# test. These tests extract the awk programs VERBATIM from the workflow file
# and run them on synthetic Packages stanzas, so the tests track the real
# published logic: if the workflow's awk changes, the fixture exercises the
# change, not a copy.
# shellcheck disable=SC2016

WORKFLOW="$PWD/.github/workflows/build.yml"

# awk_from_workflow <distinctive-substr> — print the awk program whose body
# contains the first line matching <distinctive-substr>, taken VERBATIM from
# build.yml: from the "awk '" opener just above that line to the closing-quote
# line just below, with the YAML indentation stripped. Pristine: no output
# except the program text.
awk_from_workflow() {
  local marker="$1" hit start end
  hit=$(grep -nF "$marker" "$WORKFLOW" | head -1 | cut -d: -f1)
  [ -n "$hit" ] || {
    echo "awk_from_workflow: '$marker' not found in $WORKFLOW" >&2; return 1; }
  # the opener is the nearest line ABOVE the marker that ends the "awk '"
  # opening of a program (the program runs to a following closing-quote line)
  start=$(sed -n "1,${hit}p" "$WORKFLOW" | grep -nE "awk .*'$" | tail -1 | cut -d: -f1)
  [ -n "$start" ] || {
    echo "awk_from_workflow: no 'awk ' opener above line $hit" >&2; return 1; }
  end=$(sed -n "$((start+1)),\$p" "$WORKFLOW" | grep -nE "^[[:space:]]*'" | head -1 | cut -d: -f1)
  [ -n "$end" ] || {
    echo "awk_from_workflow: no closing quote after line $start" >&2; return 1; }
  end=$((start+end))
  sed -n "$((start+1)),$((end-1))p" "$WORKFLOW" | sed 's/^[[:space:]]*//'
}

test_publish_awk_prune_drops_stanzas_whose_asset_is_missing() {
  local d prev names pruned prune_awk kept
  d=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand NOW: the local is gone by trap time
  trap "rm -rf '$d'" EXIT
  prev="$d/Packages"
  # three stanzas: the MIDDLE one's Filename is not in the release asset list
  # (a previous publish died before its upload); the LAST stanza deliberately
  # has no trailing blank line, so its flush happens in the END action, not at
  # a line break — both prune paths are exercised.
  printf '%s\n' \
    'Package: halo-kernel' \
    'Version: 7.0.0-38.38~24.04.4+halok1' \
    'Filename: linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb' \
    '' \
    'Package: orphaned-stanza' \
    'Version: 9.9.9' \
    'Filename: linux-image-orphaned.deb' \
    '' \
    'Package: halo-kernel' \
    'Version: 7.0.0-38.38~24.04.4+halok2' \
    'Filename: linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok2_amd64.deb' > "$prev"
  # the workflow feeds names from 'gh release view --json assets --jq .assets[].name':
  # ONE ASSET NAME PER LINE. The awk pads with "\n" and matches on it.
  names=$(printf '%s\n' \
    'linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb' \
    'linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok2_amd64.deb')
  prune_awk=$(awk_from_workflow 'ENVIRON["names"]') || return 1
  pruned="$d/pruned"
  names="$names" awk "$prune_awk" "$prev" > "$pruned" \
    || { echo "the prune awk must run on the fixture index" >&2; return 1; }
  # exactly the missing-asset stanza is dropped; both present-asset stanzas kept
  kept=$(grep -c '^Package:' "$pruned")
  [ "$kept" -eq 2 ] || {
    echo "prune must keep 2 stanzas, got $kept: $(cat "$pruned")" >&2; return 1; }
  if grep -qF 'linux-image-orphaned.deb' "$pruned"; then
    echo "prune must drop the stanza whose asset is missing from the release" >&2; return 1
  fi
  grep -qF 'linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb' "$pruned" \
    || { echo "prune must keep the first (present-asset) stanza" >&2; return 1; }
  grep -qF 'linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok2_amd64.deb' "$pruned" \
    || { echo "prune must keep the last stanza (no trailing blank line)" >&2; return 1; }
  # the END flush kept the last stanza ending the file: no invented blank line
  [ "$(tail -n 1 "$pruned")" = 'Filename: linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok2_amd64.deb' ] || {
    echo "the kept last stanza must end the file without a trailing blank line" >&2; return 1; }
}

test_publish_awk_prune_keeps_whole_index_when_all_assets_exist() {
  # control: with every asset present the prune must rewrite the index
  # unchanged — the routine previous-index merge path must not lose a stanza
  local d prev names pruned prune_awk
  d=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand NOW: the local is gone by trap time
  trap "rm -rf '$d'" EXIT
  prev="$d/Packages"
  printf '%s\n' \
    'Package: halo-kernel' \
    'Version: 7.0.0-38.38~24.04.4+halok1' \
    'Filename: linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb' \
    '' \
    'Package: halo-kernel' \
    'Version: 7.0.0-38.38~24.04.4+halok2' \
    'Filename: linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok2_amd64.deb' > "$prev"
  names=$(printf '%s\n' \
    'linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok1_amd64.deb' \
    'linux-image-7.0.0-38-generic_7.0.0-38.38~24.04.4+halok2_amd64.deb')
  prune_awk=$(awk_from_workflow 'ENVIRON["names"]') || return 1
  pruned="$d/pruned"
  names="$names" awk "$prune_awk" "$prev" > "$pruned" \
    || { echo "the prune awk must run on the fixture index" >&2; return 1; }
  cmp -s "$prev" "$pruned" || {
    echo "prune must rewrite the index unchanged when every asset exists" >&2; return 1; }
}

test_publish_awk_resign_selects_meta_stanzas_only() {
  local d prev out resign_awk rc=0 want want2
  d=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand NOW: the local is gone by trap time
  trap "rm -rf '$d'" EXIT
  prev="$d/Packages"
  # two halo-meta stanzas plus one unrelated kernel stanza: the re-sign run's
  # selection must hand back ONLY the meta stanzas, as '<version>\t<filename>'
  printf '%s\n' \
    'Package: linux-image-halo-noble' \
    'Version: 7.0.0-38.38~24.04.4+halok1' \
    'Filename: linux-image-halo-noble_7.0.0-38.38~24.04.4+halok1_amd64.deb' \
    '' \
    'Package: linux-image-unsigned-7.0.0-38-generic' \
    'Version: 7.0.0-38.38~24.04.4' \
    'Filename: linux-image-unsigned-7.0.0-38-generic_7.0.0-38.38~24.04.4_amd64.deb' \
    '' \
    'Package: linux-image-halo-noble' \
    'Version: 7.0.0-38.38~24.04.4+halok2' \
    'Filename: linux-image-halo-noble_7.0.0-38.38~24.04.4+halok2_amd64.deb' > "$prev"
  resign_awk=$(awk_from_workflow 'print v "\t" substr($0, 11)') || return 1
  # the workflow runs it as: awk -v meta="linux-image-halo-$s" <program> "$prev"
  out=$(awk -v meta='linux-image-halo-noble' "$resign_awk" "$prev") || rc=$?
  [ "$rc" -eq 0 ] || { echo "the resign awk must run on the fixture index" >&2; return 1; }
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] || {
    echo "the resign awk must select the two halo-meta stanzas, got: $out" >&2; return 1; }
  want=$'7.0.0-38.38~24.04.4+halok1\tlinux-image-halo-noble_7.0.0-38.38~24.04.4+halok1_amd64.deb'
  want2=$'7.0.0-38.38~24.04.4+halok2\tlinux-image-halo-noble_7.0.0-38.38~24.04.4+halok2_amd64.deb'
  grep -Fqx "$want" <<<"$out" || {
    echo "the resign selection must carry each meta's version and filename: $out" >&2; return 1; }
  grep -Fqx "$want2" <<<"$out" || {
    echo "the resign selection must carry the newer meta's version and filename" >&2; return 1; }
  if grep -q 'linux-image-unsigned' <<<"$out"; then
    echo "the resign awk must not select non-meta stanzas" >&2; return 1
  fi
}
