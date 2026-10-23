#!/usr/bin/env bash
# Builds supabase/setup/01_bizpilot_setup.sql: every migration in order, in one transaction,
# for pasting into the Supabase SQL Editor. Re-run after adding a migration.
set -euo pipefail
cd "$(dirname "$0")/.."
out=supabase/setup/01_bizpilot_setup.sql
{
  echo "-- BizPilot: complete database setup (all migrations in order)."
  echo "-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE on an empty project."
  echo "-- Generated from supabase/migrations by scripts/build-setup-sql.sh - do not edit by hand."
  echo "begin;"
  for f in supabase/migrations/*.sql; do echo; echo "-- ===== $(basename "$f") ====="; cat "$f"; done
  echo
  echo "commit;"
} > "$out"
echo "wrote $out"
