#!/usr/bin/env bash
#
# Checks that a host app cannot run Loupe in production. Copy this into your own
# repository - it is written for your app, not for Loupe's.
#
#   bash check-host-guard.sh                       # reachability, in the current directory
#   bash check-host-guard.sh . path/to/MyApp       # and count symbols in a Release binary
#
# There are two different questions here and they have two different answers. Mixing
# them up costs an afternoon, so this script keeps them apart.
#
# 1. CAN LOUPE RUN?  This is the one that matters, and it is answerable everywhere.
#    Every call site must sit inside `#if DEBUG` (or your own staging flag). If none
#    can be reached, nothing observes anything, no window is created, and no behaviour
#    ships - whatever the binary contains.
#
# 2. IS LOUPE IN THE BINARY?  On Apple, usually yes, even when 1 is perfect. Xcode
#    links a Swift package product whole rather than pulling in only what is
#    referenced. 782 Loupe symbols were measured in a Release build of a real app
#    whose guard was correct. That is not a broken guard and chasing it as one is the
#    trap this script exists to stop.
#
#    To remove the symbols as well, the dependency has to be absent from the build,
#    not guarded inside it. See "Removing the symbols" in Loupe's docs/agent-install.md.
set -uo pipefail

root="${1:-.}"
binary="${2:-}"
status=0

echo "==> 1. Can Loupe run? (every call site guarded)"
# `Loupe.` catches the entry points; the recorders are named separately because they
# install global hooks and are the ones people forget.
unguarded=$(grep -rn --include="*.swift" \
  -E "\b(Loupe|LoupeLinear)\.[a-z]|NetworkRecorder\.install|LogRecorder\.install" \
  "$root" 2>/dev/null \
  | grep -v "/\.build/" | grep -v "/DerivedData/" || true)

if [ -z "$unguarded" ]; then
  echo "    no call sites found at all - is this the right directory?"
else
  # A call site is guarded when a `#if DEBUG` opens above it and no `#endif` has closed
  # it yet. Checked per file rather than per line, because that is how the compiler
  # reads it.
  bad=0
  while IFS= read -r file; do
    awk -v f="$file" '
      /^[[:space:]]*#if[[:space:]]+DEBUG/ { depth++; next }
      /^[[:space:]]*#if[[:space:]]/ { if (depth > 0) depth++; next }
      /^[[:space:]]*#endif/ { if (depth > 0) depth--; next }
      {
        line = $0
        # A mention in a comment is not a call site. Doc comments explaining the API
        # are the commonest false positive and the fastest way to make somebody stop
        # trusting a check like this.
        sub(/\/\/.*/, "", line)
        if (line ~ /(Loupe|LoupeLinear)\.[a-z]|NetworkRecorder\.install|LogRecorder\.install/) {
          if (depth == 0) printf "    UNGUARDED  %s:%d  %s\n", f, NR, $0
        }
      }
    ' "$file"
  done < <(echo "$unguarded" | cut -d: -f1 | sort -u) > /tmp/loupe-guard-$$ 2>/dev/null

  if [ -s /tmp/loupe-guard-$$ ]; then
    cat /tmp/loupe-guard-$$
    echo
    echo "    Each of these can run in a Release build. Put it inside #if DEBUG"
    echo "    (or your own staging flag) before shipping."
    status=1
    bad=1
  fi
  rm -f /tmp/loupe-guard-$$
  [ "$bad" = 0 ] && echo "    every call site is guarded"
fi

if [ -n "$binary" ]; then
  echo
  echo "==> 2. Is Loupe in the binary? (informational, not a gate)"
  if [ ! -f "$binary" ]; then
    echo "    no such file: $binary"
  else
    count=$(nm -gU "$binary" 2>/dev/null | grep -c "Loupe" || true)
    echo "    $count Loupe symbols in $(basename "$binary")"
    if [ "$count" -gt 0 ]; then
      echo "    Expected on Apple, and NOT a failed guard. Xcode links a package"
      echo "    product whole. If you need them gone, the dependency has to be absent"
      echo "    from the build rather than guarded inside it - see"
      echo "    'Removing the symbols' in Loupe's docs/agent-install.md."
    fi
  fi
fi

exit $status
