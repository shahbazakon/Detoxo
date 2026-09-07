#!/usr/bin/env bash
# Feature-isolation boundary check (run via tool/dev.sh precommit).
#
# Rule: a feature may import another feature's PUBLIC barrel or its domain/,
# but never reach into another feature's data/ or presentation/ internals.
# Composition roots are exempt (they exist to wire features together):
#   lib/app/**, lib/core/di/**, lib/core/navigation/**,
#   lib/features/dashboard/** (shell), lib/features/settings/** (orchestrator).
#
# Baseline: this script grepped a pre-rebrand package prefix until Aug 2026 — i.e.
# it matched nothing and passed vacuously from the rename onward. Fixing the grep
# surfaced 12 pre-existing violations at once. They are listed in
# tool/boundaries_baseline.txt and reported as warnings so the gate can be
# enforced today; anything NOT on that list fails the build. Burn the list down
# and delete it — do not add to it.
set -euo pipefail
cd "$(dirname "$0")/.."

baseline_file="tool/boundaries_baseline.txt"
violations=0
grandfathered=0
while IFS= read -r -d '' file; do
  case "$file" in
    lib/app/*|lib/core/di/*|lib/core/navigation/*|\
    lib/features/dashboard/*|lib/features/settings/*) continue ;;
  esac
  # the importing file's own top-level feature (…/features/<name>/…)
  self=$(printf '%s' "$file" | sed -nE 's#^lib/features/([^/]+)/.*#\1#p')
  # forbidden: importing another feature's data/ or presentation/
  while IFS= read -r line; do
    # `(.*/)?` — the module segment is optional, exactly as in the grep below.
    # With a REQUIRED segment this extraction returned nothing for a feature's
    # top-level data/ or presentation/ (…/features/dashboard/presentation/…),
    # so those imports were skipped and the gate passed vacuously for them
    # (found 2026-09-06, with two such imports live and the baseline empty).
    other=$(printf '%s' "$line" | sed -nE "s#.*package:detoxo/features/([^/]+)/(.*/)?(data|presentation)/.*#\1#p")
    [ -z "$other" ] && continue
    [ "$other" = "$self" ] && continue
    # Key on file + imported path (not line number, which shifts on any edit).
    import=$(printf '%s' "$line" | sed -nE "s#.*(package:detoxo/[^']+)'.*#\1#p")
    if [ -f "$baseline_file" ] && grep -qxF "$file $import" "$baseline_file"; then
      echo "  (known) $file -> $import"
      grandfathered=$((grandfathered+1))
      continue
    fi
    echo "BOUNDARY VIOLATION: $file"
    echo "    -> $line"
    violations=$((violations+1))
  done < <(grep -nE "package:detoxo/features/[^/]+/(.*/)?(data|presentation)/" "$file" || true)
done < <(find lib/features -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' -print0)

if [ "$violations" -gt 0 ]; then
  echo ""
  echo "✗ $violations NEW feature-boundary violation(s) found."
  exit 1
fi
if [ "$grandfathered" -gt 0 ]; then
  echo ""
  echo "⚠ $grandfathered known violation(s) from $baseline_file — burn these down."
fi
echo "✓ No new feature-boundary violations."
