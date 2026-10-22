create extension if not exists plpgsql_check;
select p.oid::regprocedure || ' | ' || coalesce(r.lineno::text,'') || ' | ' || r.message || coalesce(' | ' || left(r.query,160), '')
from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang
cross join lateral plpgsql_check_function_tb(p.oid, fatal_errors := false, extra_warnings := false, performance_warnings := false) r
where n.nspname in ('public','app') and l.lanname='plpgsql' and p.prorettype <> 'trigger'::regtype
and r.level = 'error' and r.message !~ 'relation "_(sl|avail|owed|cpay|cowed)" does not exist' and r.message !~ 'is not assigned yet';
