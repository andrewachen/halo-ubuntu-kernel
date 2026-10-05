# shellcheck shell=bash
# apt-src.sh — shared deb-src access with an isolated apt state dir, so no root
# is needed and check/build workflows share identical apt config. Sourced.
# Requires REPO = repo root; each series' pockets live in series/<s>/series.env.
# apt_src_update <series> <workdir> — apt-get update against the series' pockets
# apt_src_showsrc <series> <workdir> <source_pkg> — showsrc for one source package
# apt_src_download <series> <workdir> <pkg=version> — download one pinned source
#   version into the caller's cwd (--download-only, no extraction), same
#   isolated state, so the build's fetch needs no root either
_prepare_apt_state() {  # <series> <workdir> — env + src.list + the dirs apt requires
  local series="$1" workdir="$2" p
  # shellcheck disable=SC1090 # series path is a runtime arg, not resolvable statically
  . "$REPO/series/$series/series.env" || return 1
  : > "$workdir/src.list"
  for p in $POCKETS; do
    printf 'deb-src http://archive.ubuntu.com/ubuntu %s main\n' "$p" >> "$workdir/src.list"
  done
  # apt refuses to run when these dirs are missing under an isolated Dir::State/Dir::Cache.
  mkdir -p "$workdir/lists/partial" "$workdir/cache/archives/partial" || return 1
}
# Both functions run apt with the series' own src.list and isolated state/cache
# dirs under <workdir>, so a non-root caller never touches the system apt state.
# update's progress output (Hit:/Get: lines) goes to stderr so a caller like
# check-upstream-helper.sh can hand its clean stdout to check-upstream.sh.
apt_src_update() {  # <series> <workdir>
  local series="$1" workdir="$2"
  _prepare_apt_state "$series" "$workdir" || return 1
  apt-get -o Dir::Etc::sourcelist="$workdir/src.list" \
    -o Dir::Etc::sourceparts=- \
    -o Dir::State::Lists="$workdir/lists" \
    -o Dir::Cache="$workdir/cache" \
    update >&2
}
apt_src_showsrc() {  # <series> <workdir> <source_pkg>
  local series="$1" workdir="$2" pkg="$3"
  _prepare_apt_state "$series" "$workdir" || return 1
  # showsrc is an apt-cache operation (apt-get has no showsrc); the -o options
  # keep it on the isolated state so no root and no system apt state are needed.
  apt-cache -o Dir::Etc::sourcelist="$workdir/src.list" \
    -o Dir::Etc::sourceparts=- \
    -o Dir::State::Lists="$workdir/lists" \
    -o Dir::Cache="$workdir/cache" \
    showsrc "$pkg"
}
apt_src_download() {  # <series> <workdir> <pkg=version> — downloads land in the cwd
  local series="$1" workdir="$2" pkg="$3"
  _prepare_apt_state "$series" "$workdir" || return 1
  # --download-only fetches the pinned version's files without extracting;
  # the same -o options keep it on the isolated state (no root, no system apt).
  apt-get -o Dir::Etc::sourcelist="$workdir/src.list" \
    -o Dir::Etc::sourceparts=- \
    -o Dir::State::Lists="$workdir/lists" \
    -o Dir::Cache="$workdir/cache" \
    source --download-only "$pkg"
}
