\set ON_ERROR_STOP on

select pg_advisory_lock(64017, 2);

begin transaction isolation level repeatable read;
select refresh_property_market_metrics(:year::smallint);
commit;

\echo Refreshed property market metrics for :year
select pg_advisory_unlock(64017, 2);
