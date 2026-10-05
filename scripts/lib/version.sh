# shellcheck shell=bash
# version.sh — +halokN arithmetic and EVR↔tag mapping. Sourced.
append_halo_suffix() { printf '%s+halok%s\n' "$1" "$2"; }
strip_halo_suffix() { printf '%s\n' "${1%+halok*}"; }
_halo_n_of() { case "$1" in *+halok*) printf '%s\n' "${1##*+halok}" ;; esac; }
next_halo_n() {  # <upstream> <versions...>
  local want="$1" v n max=0; shift
  for v in "$@"; do
    [ "$(strip_halo_suffix "$v")" = "$want" ] || continue
    n=$(_halo_n_of "$v"); case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max=$n
  done
  echo $((max + 1))
}
newest_deb_version() {  # stdin: apt-cache showsrc output
  local v best=""
  while IFS= read -r line; do
    case "$line" in Version:*) v="${line#Version: }"; v="${v// /}"
      if [ -z "$best" ] || dpkg --compare-versions "$v" gt "$best" 2>/dev/null; then best="$v"; fi ;;
    esac
  done
  [ -n "$best" ] || { echo "no Version: lines on stdin" >&2; return 1; }
  printf '%s\n' "$best"
}
# Git refnames forbid '~'. EVR↔tag: '~'↔'_'. Ubuntu EVRs never contain '_'.
# NOTE: the tilde in the replacement must be escaped or bash expands it to $HOME.
# Reject EVRs that can't map to a valid refname ('~' is mapped; ':' and
# whitespace are not) instead of silently emitting an unusable tag.
tag_for_version() {  # <series> <EVR> — fails loudly if EVR would make an invalid refname
  case "$2" in *:*|*[[:space:]]*) echo "tag_for_version: EVR '$2' contains ':' or whitespace — would be an invalid git refname" >&2; return 1 ;; esac
  local rest="${2//\~/_}"
  printf '%s-%s\n' "$1" "$rest"
}
version_from_tag() { local rest="${1#*-}"; printf '%s\n' "${rest//_/\~}"; }
