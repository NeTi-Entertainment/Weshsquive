\set ON_ERROR_STOP on

select pg_advisory_lock(64017, 1);

begin transaction isolation level repeatable read;

insert into search_metric_snapshots default values
returning snapshot_id \gset

insert into search_metrics_city_year_category (
    snapshot_id,
    city_insee_code,
    year,
    category_id,
    category_code,
    category_label,
    incident_count,
    rate_per_1000,
    publication_status,
    source,
    imported_at,
    count_unit,
    rate_denominator_reference,
    rate_denominator,
    insee_pop,
    insee_pop_millesime,
    insee_log,
    insee_log_millesime
)
select
    :snapshot_id,
    metrics.city_insee_code,
    metrics.year,
    metrics.category_id,
    metrics.category_code,
    metrics.category_label,
    metrics.incident_count,
    metrics.rate_per_1000,
    metrics.publication_status,
    metrics.source,
    metrics.imported_at,
    metrics.count_unit,
    metrics.rate_denominator_reference,
    metrics.rate_denominator,
    metrics.insee_pop,
    metrics.insee_pop_millesime,
    metrics.insee_log,
    metrics.insee_log_millesime
from city_year_category_metrics metrics;

insert into search_metrics_city_year_comparative (
    snapshot_id,
    city_insee_code,
    year,
    population,
    population_year,
    population_band,
    published_category_count,
    total_category_count,
    coverage_ratio,
    availability_mask,
    published_basket_category_count,
    cohort_size,
    comparative_index_status,
    comparative_index,
    comparative_index_confidence,
    basket_version
)
select
    :snapshot_id,
    metrics.city_insee_code,
    metrics.year,
    metrics.population,
    metrics.population_year,
    metrics.population_band,
    metrics.published_category_count,
    metrics.total_category_count,
    metrics.coverage_ratio,
    metrics.availability_mask,
    metrics.published_basket_category_count,
    metrics.cohort_size,
    metrics.comparative_index_status,
    metrics.comparative_index,
    metrics.comparative_index_confidence,
    metrics.basket_version
from city_year_comparative_metrics metrics;

insert into search_metrics_active (singleton, snapshot_id)
values (true, :snapshot_id)
on conflict (singleton) do update
set snapshot_id = excluded.snapshot_id;

delete from search_metric_snapshots
where snapshot_id <> :snapshot_id
  and snapshot_id not in (
      select snapshot_id
      from search_metric_snapshots
      order by created_at desc, snapshot_id desc
      limit 2
  );

commit;

\echo Activated search metric snapshot :snapshot_id
select pg_advisory_unlock(64017, 1);
