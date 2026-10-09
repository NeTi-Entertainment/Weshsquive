alter table crime_categories
    add column if not exists rate_denominator_reference text not null default 'unknown';

alter table crime_categories
    drop constraint if exists crime_categories_rate_denominator_reference_check;

alter table crime_categories
    add constraint crime_categories_rate_denominator_reference_check
        check (rate_denominator_reference in ('population', 'housing', 'unknown'));

alter table crime_stats
    add column if not exists count_unit text,
    add column if not exists insee_pop bigint,
    add column if not exists insee_pop_millesime smallint,
    add column if not exists insee_log bigint,
    add column if not exists insee_log_millesime smallint,
    add column if not exists complement_info_nombre numeric(18, 6),
    add column if not exists complement_info_taux numeric(18, 6),
    add column if not exists rate_denominator text not null default 'unknown';

alter table crime_stats
    drop constraint if exists crime_stats_rate_denominator_check;

alter table crime_stats
    add constraint crime_stats_rate_denominator_check
        check (rate_denominator in ('population', 'housing', 'unknown'));

alter table crime_stats
    drop constraint if exists crime_stats_ssmsi_denominators_check;

alter table crime_stats
    add constraint crime_stats_ssmsi_denominators_check
        check (
            (insee_pop is null or insee_pop >= 0)
            and (insee_log is null or insee_log >= 0)
            and (complement_info_nombre is null or complement_info_nombre >= 0)
            and (complement_info_taux is null or complement_info_taux >= 0)
        );

drop view city_year_comparative_metrics;

create or replace view city_year_category_metrics as
select distinct on (cs.city_insee_code, cs.year, cs.category_id)
    cs.city_insee_code,
    cs.year,
    cs.category_id,
    cc.code as category_code,
    cc.label as category_label,
    cs.incident_count,
    cs.rate_per_1000,
    cs.publication_status,
    cs.source,
    cs.imported_at,
    cs.count_unit,
    cc.rate_denominator_reference,
    cs.rate_denominator,
    cs.insee_pop,
    cs.insee_pop_millesime,
    cs.insee_log,
    cs.insee_log_millesime
from crime_stats cs
join crime_categories cc on cc.id = cs.category_id
order by
    cs.city_insee_code,
    cs.year,
    cs.category_id,
    cs.imported_at desc,
    cs.id desc;

create view city_year_comparative_metrics as
with basket(category_code, availability_bit) as (
    values
        ('ssmsi-78384436563146dc6167ea53b7b5e0cd'::text, 1),
        ('ssmsi-74a195792dd119f60822e61df3587522'::text, 2),
        ('ssmsi-d3e9d2e40d72b8850d5283eb73bdc928'::text, 4),
        ('ssmsi-bf6b19b3e53b90f6594ec2e8303c5778'::text, 8),
        ('ssmsi-a2601b900aa009440624697e1d74e4a9'::text, 16),
        ('ssmsi-bdbeb8ca73503f8264dab16159795328'::text, 32)
),
years as (
    select distinct year from city_year_category_metrics
),
city_year_population as (
    select
        c.insee_code as city_insee_code,
        years.year,
        coalesce(population.population, c.reference_population) as population,
        coalesce(population.year, c.population_year) as population_year,
        case
            when coalesce(population.population, c.reference_population) is null then null
            when coalesce(population.population, c.reference_population) < 1000 then 'under-1000'
            when coalesce(population.population, c.reference_population) < 5000 then '1000-4999'
            when coalesce(population.population, c.reference_population) < 10000 then '5000-9999'
            when coalesce(population.population, c.reference_population) < 50000 then '10000-49999'
            when coalesce(population.population, c.reference_population) < 100000 then '50000-99999'
            else '100000-plus'
        end as population_band
    from cities c
    cross join years
    left join lateral (
        select ph.population, ph.year
        from population_history ph
        where ph.city_insee_code = c.insee_code
          and ph.year <= years.year
          and ph.population is not null
        order by ph.year desc, ph.imported_at desc
        limit 1
    ) population on true
),
expected_categories as (
    select year, count(distinct category_id)::integer as total_category_count
    from city_year_category_metrics
    group by year
),
basket_rates as (
    select
        cy.city_insee_code,
        cy.year,
        cy.population_band,
        category.category_code,
        category.count_unit,
        category.rate_denominator,
        category.rate_per_1000
    from city_year_population cy
    join city_year_category_metrics category
      on category.city_insee_code = cy.city_insee_code
     and category.year = cy.year
    join basket on basket.category_code = category.category_code
    where category.publication_status = 'published'
      and category.rate_per_1000 is not null
      and category.count_unit is not null
      and category.rate_denominator in ('population', 'housing')
      and cy.population_band is not null
),
basket_category_percentiles as (
    select
        city_insee_code,
        year,
        category_code,
        percent_rank() over (
            partition by year, population_band, category_code, count_unit, rate_denominator
            order by rate_per_1000
        ) as category_percentile
    from basket_rates
),
city_year_summary as (
    select
        cy.city_insee_code,
        cy.year,
        cy.population,
        cy.population_year,
        cy.population_band,
        coalesce(expected.total_category_count, 0) as total_category_count,
        count(category.category_id) filter (
            where category.publication_status = 'published'
        )::integer as published_category_count,
        case
            when coalesce(expected.total_category_count, 0) > 0
                then count(category.category_id) filter (
                    where category.publication_status = 'published'
                )::numeric / expected.total_category_count
            else null
        end as coverage_ratio,
        coalesce(
            bit_or(basket.availability_bit) filter (
                where category.publication_status = 'published'
                  and category.rate_per_1000 is not null
                  and category.count_unit is not null
                  and category.rate_denominator in ('population', 'housing')
            ),
            0
        )::integer as availability_mask,
        count(category.category_id) filter (
            where basket.availability_bit is not null
              and category.publication_status = 'published'
              and category.rate_per_1000 is not null
              and category.count_unit is not null
              and category.rate_denominator in ('population', 'housing')
        )::integer as published_basket_category_count,
        avg(percentiles.category_percentile) as average_category_percentile
    from city_year_population cy
    left join expected_categories expected on expected.year = cy.year
    left join city_year_category_metrics category
      on category.city_insee_code = cy.city_insee_code
     and category.year = cy.year
    left join basket on basket.category_code = category.category_code
    left join basket_category_percentiles percentiles
      on percentiles.city_insee_code = category.city_insee_code
     and percentiles.year = category.year
     and percentiles.category_code = category.category_code
    group by
        cy.city_insee_code,
        cy.year,
        cy.population,
        cy.population_year,
        cy.population_band,
        expected.total_category_count
),
eligible_cohort_sizes as (
    select
        year,
        population_band,
        availability_mask,
        count(*)::integer as cohort_size
    from city_year_summary
    where published_basket_category_count >= 3
      and population > 0
      and average_category_percentile is not null
    group by year, population_band, availability_mask
),
ranked_indices as (
    select
        summary.city_insee_code,
        summary.year,
        round(
            percent_rank() over (
                partition by summary.year, summary.population_band, summary.availability_mask
                order by summary.average_category_percentile
            ) * 100
        )::integer as comparative_index
    from city_year_summary summary
    join eligible_cohort_sizes cohorts
      on cohorts.year = summary.year
     and cohorts.population_band = summary.population_band
     and cohorts.availability_mask = summary.availability_mask
     and cohorts.cohort_size >= 50
    where summary.published_basket_category_count >= 3
      and summary.population > 0
      and summary.average_category_percentile is not null
)
select
    summary.city_insee_code,
    summary.year,
    summary.population,
    summary.population_year,
    summary.population_band,
    summary.published_category_count,
    summary.total_category_count,
    summary.coverage_ratio,
    summary.availability_mask,
    summary.published_basket_category_count,
    coalesce(cohorts.cohort_size, 0) as cohort_size,
    case
        when summary.population is null or summary.population <= 0 then 'population-unavailable'
        when summary.published_basket_category_count < 3 then 'insufficient-coverage'
        when coalesce(cohorts.cohort_size, 0) < 50 then 'cohort-too-small'
        else 'comparable'
    end as comparative_index_status,
    case
        when summary.population > 0
          and summary.published_basket_category_count >= 3
          and coalesce(cohorts.cohort_size, 0) >= 50
            then indices.comparative_index
        else null
    end as comparative_index,
    case
        when summary.population > 0
          and summary.published_basket_category_count >= 3
          and coalesce(cohorts.cohort_size, 0) >= 50
          then case
              when summary.published_basket_category_count = 6 then 'high'
              when summary.published_basket_category_count >= 4 then 'medium'
              else 'low'
          end
        else null
    end as comparative_index_confidence,
    'residential-risk-v1'::text as basket_version
from city_year_summary summary
left join eligible_cohort_sizes cohorts
  on cohorts.year = summary.year
 and cohorts.population_band = summary.population_band
 and cohorts.availability_mask = summary.availability_mask
left join ranked_indices indices
  on indices.city_insee_code = summary.city_insee_code
 and indices.year = summary.year;
