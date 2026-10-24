#!/usr/bin/env bash
# Builds the SQL to upgrade an existing BizPilot database (one that already ran the setup SQL)
# with the given migrations, in one transaction, for the Supabase SQL Editor.
# Usage: scripts/build-upgrade-sql.sh OUT.sql migration1.sql [migration2.sql ...]
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; shift
{
  echo "-- BizPilot upgrade: $(for f in "$@"; do basename "$f" .sql; done | tr '\n' ' ')"
  echo "-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE."
  echo "-- Adds features only: existing businesses, products, sales and users are not changed."
  echo "begin;"
  # Comment-only lines are left out to keep the file small enough for the SQL Editor.
  for f in "$@"; do echo; echo "-- ===== $(basename "$f") ====="; grep -v -E '^\s*--' "$f" | grep -v -E '^\s*$'; done
  echo
  echo "commit;"
} > "$out"
echo "wrote $out ($(wc -c < "$out") bytes)"
