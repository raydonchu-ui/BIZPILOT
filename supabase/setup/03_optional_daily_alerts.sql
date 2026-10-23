-- Optional. Creates stock / credit / renewal alerts every morning even if nobody opens the app.
-- First enable the "pg_cron" extension: Dashboard -> Database -> Extensions -> search "pg_cron" -> enable.
-- 05:15 UTC = 06:15 in Cameroon.
select cron.schedule('bizpilot-alerts', '15 5 * * *', $$ select app.generate_all_alerts() $$);
