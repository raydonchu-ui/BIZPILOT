#!/usr/bin/env bash
# Rebuilds the marketplace upgrade for existing databases: 05 (one transaction) and 05a + 05b (two
# smaller files for the SQL Editor). Each starts with a check that it runs in the right order, once.
set -euo pipefail
cd "$(dirname "$0")/.."
m1=supabase/migrations/20261025000100_marketplace.sql
m2=supabase/migrations/20261025000200_marketplace_payments_admin.sql
scripts/build-upgrade-sql.sh supabase/setup/05_upgrade_marketplace.sql scripts/sql/check_before_05.sql "$m1" "$m2"
scripts/build-upgrade-sql.sh supabase/setup/05a_upgrade_marketplace_part1.sql scripts/sql/check_before_05.sql "$m1"
scripts/build-upgrade-sql.sh supabase/setup/05b_upgrade_marketplace_part2.sql scripts/sql/check_before_05b.sql "$m2"
