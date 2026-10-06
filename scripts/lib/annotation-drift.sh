# shellcheck shell=bash
# annotation-drift.sh — classify the drift lines the Ubuntu packaging's
# `annotations --check` prints when the built .config disagrees with the
# packaged annotations. Sourced; pure functions, no side effects.
#
# The build overrides the packaging's pinned compiler (COMPILER_OVERRIDE or a
# newer native gcc), which legitimately flips CONFIG_CC_HAS_* compiler-
# capability probes; those are the ONLY drift we auto-repair, via the
# packaging's own annotations --write. Anything else is a real config change
# and must hard-fail the build.
#
# parse_check_config_drift <output-of-annotations---check>
#   Prints one "option=value" pair per REPAIRABLE drift (CONFIG_CC_HAS_*
#   drifted TO y), and returns:
#     0  drift found, all of it repairable
#     1  no drift at all
#     2  drift found but NOT repairable (details on stderr)
parse_check_config_drift() {
  local out="$1" opt new repairable='' bad=0
  # Real line shape (from the first real builds):
  #   check-config: CONFIG_CC_HAS_KASAN_SW_TAGS changed from - to y: policy<...>)
  while IFS= read -r line; do
    opt=$(printf '%s' "$line" | sed -n 's/^check-config: \(CONFIG_[A-Z0-9_]*\) changed from [^ ]* to \([^ :]\+\).*/\1/p')
    [ -n "$opt" ] || continue
    new=$(printf '%s' "$line" | sed -n 's/^check-config: '"$opt"' changed from [^ ]* to \([^ :]\+\).*/\1/p')
    case "$opt" in
      CONFIG_CC_HAS_*)
        if [ "$new" = "y" ]; then
          repairable+="$opt=y"$'\n'
        else
          echo "annotation-drift: CONFIG_CC_HAS_* probe drifted to '$new' (only 'y' is repairable): $line" >&2
          bad=1
        fi
        ;;
      *)
        echo "annotation-drift: non-probe config drift is NOT auto-repairable: $line" >&2
        bad=1
        ;;
    esac
  done <<EOF
$out
EOF
  # any non-repairable drift is fatal even if other probes were parseable:
  # the caller must never proceed past a build the packaging check rejects
  if [ "$bad" != 0 ]; then
    return 2
  fi
  if [ -n "$repairable" ]; then
    printf '%s' "$repairable"
    return 0
  fi
  return 1
}
