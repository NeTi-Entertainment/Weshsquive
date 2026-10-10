alter table search_metrics_city_year_category
    add column if not exists complement_info_nombre numeric(18, 6),
    add column if not exists complement_info_taux numeric(18, 6);

alter table search_metrics_city_year_comparative
    add column if not exists estimated_basket_category_count integer,
    add column if not exists comparable_basket_category_count integer,
    add column if not exists estimated_availability_mask integer,
    add column if not exists minimum_reference_cohort_size integer,
    add column if not exists comparative_index_provenance text;

with denominator_reference(category_label, denominator) as (
    values
        ('Cambriolages de logement'::text, 'housing'::text),
        ('Destructions et dégradations volontaires'::text, 'population'::text),
        ('Escroqueries et fraudes aux moyens de paiement'::text, 'population'::text),
        ('Trafic de stupéfiants'::text, 'population'::text),
        ('Usage de stupéfiants'::text, 'population'::text),
        ('Usage de stupéfiants (AFD)'::text, 'population'::text),
        ('Violences physiques hors cadre familial'::text, 'population'::text),
        ('Violences physiques intrafamiliales'::text, 'population'::text),
        ('Violences sexuelles'::text, 'population'::text),
        ('Vols avec armes'::text, 'population'::text),
        ('Vols d''accessoires sur véhicules'::text, 'population'::text),
        ('Vols dans les véhicules'::text, 'population'::text),
        ('Vols de véhicule'::text, 'population'::text),
        ('Vols sans violence contre des personnes'::text, 'population'::text),
        ('Vols violents sans arme'::text, 'population'::text)
)
update crime_categories category
set rate_denominator_reference = reference.denominator
from denominator_reference reference
where reference.category_label = category.label
  and category.rate_denominator_reference is distinct from reference.denominator;

with corrected_denominators as (
    select
        statistic.id,
        case
            when category.rate_denominator_reference = 'unknown' then 'unknown'
            when statistic.publication_status = 'masked'
                then category.rate_denominator_reference
            when statistic.publication_status = 'published'
              and statistic.count_unit is not null
              and statistic.incident_count is not null
              and statistic.rate_per_1000 is not null
              and case category.rate_denominator_reference
                  when 'population' then statistic.insee_pop is not null
                      and statistic.insee_pop > 0
                      and abs(
                          statistic.rate_per_1000
                          - statistic.incident_count::numeric * 1000 / statistic.insee_pop
                      ) <= 0.0051
                  when 'housing' then statistic.insee_log is not null
                      and statistic.insee_log > 0
                      and abs(
                          statistic.rate_per_1000
                          - statistic.incident_count::numeric * 1000 / statistic.insee_log
                      ) <= 0.0051
                  else false
              end
                then category.rate_denominator_reference
            else 'unknown'
        end as rate_denominator
    from crime_stats statistic
    join crime_categories category on category.id = statistic.category_id
)
update crime_stats statistic
set rate_denominator = corrected.rate_denominator
from corrected_denominators corrected
where corrected.id = statistic.id
  and statistic.rate_denominator is distinct from corrected.rate_denominator;

drop view if exists city_year_comparative_metrics;
drop view if exists city_year_comparative_components;

create or replace view city_year_category_metrics as
select distinct on (statistic.city_insee_code, statistic.year, statistic.category_id)
    statistic.city_insee_code,
    statistic.year,
    statistic.category_id,
    category.code as category_code,
    category.label as category_label,
    statistic.incident_count,
    statistic.rate_per_1000,
    statistic.publication_status,
    statistic.source,
    statistic.imported_at,
    statistic.count_unit,
    category.rate_denominator_reference,
    statistic.rate_denominator,
    statistic.insee_pop,
    statistic.insee_pop_millesime,
    statistic.insee_log,
    statistic.insee_log_millesime,
    statistic.complement_info_nombre,
    statistic.complement_info_taux
from crime_stats statistic
join crime_categories category on category.id = statistic.category_id
order by
    statistic.city_insee_code,
    statistic.year,
    statistic.category_id,
    statistic.imported_at desc,
    statistic.id desc;

create view city_year_comparative_components as
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
        city.insee_code as city_insee_code,
        years.year,
        coalesce(population.population, city.reference_population) as population,
        coalesce(population.year, city.population_year) as population_year,
        case
            when coalesce(population.population, city.reference_population) is null then null
            when coalesce(population.population, city.reference_population) < 1000 then 'under-1000'
            when coalesce(population.population, city.reference_population) < 5000 then '1000-4999'
            when coalesce(population.population, city.reference_population) < 10000 then '5000-9999'
            when coalesce(population.population, city.reference_population) < 50000 then '10000-49999'
            else '50000-plus'
        end as population_band
    from cities city
    cross join years
    left join lateral (
        select history.population, history.year
        from population_history history
        where history.city_insee_code = city.insee_code
          and history.year <= years.year
          and history.population is not null
        order by history.year desc, history.imported_at desc
        limit 1
    ) population on true
),
component_candidates as (
    select
        city_year.city_insee_code,
        city_year.year,
        city_year.population,
        city_year.population_year,
        city_year.population_band,
        basket.category_code,
        basket.availability_bit,
        statistic.count_unit,
        statistic.rate_denominator,
        case
            when statistic.publication_status = 'published'
              and statistic.rate_per_1000 is not null
              and statistic.count_unit is not null
              and statistic.rate_denominator in ('population', 'housing')
                then 'published'
            when statistic.publication_status = 'masked'
              and statistic.complement_info_taux is not null
              and statistic.count_unit is not null
              and statistic.rate_denominator in ('population', 'housing')
                then 'department-masked-average'
            else null
        end as component_source,
        case
            when statistic.publication_status = 'published'
              and statistic.rate_per_1000 is not null
              and statistic.count_unit is not null
              and statistic.rate_denominator in ('population', 'housing')
                then statistic.rate_per_1000
            when statistic.publication_status = 'masked'
              and statistic.complement_info_taux is not null
              and statistic.count_unit is not null
              and statistic.rate_denominator in ('population', 'housing')
                then statistic.complement_info_taux
            else null
        end as effective_rate_per_1000
    from city_year_population city_year
    cross join basket
    left join city_year_category_metrics statistic
      on statistic.city_insee_code = city_year.city_insee_code
     and statistic.year = city_year.year
     and statistic.category_code = basket.category_code
),
published_references as (
    select
        statistic.city_insee_code,
        statistic.year,
        population.population_band,
        statistic.category_code,
        statistic.count_unit,
        statistic.rate_denominator,
        statistic.rate_per_1000
    from city_year_category_metrics statistic
    join city_year_population population
      on population.city_insee_code = statistic.city_insee_code
     and population.year = statistic.year
    join basket on basket.category_code = statistic.category_code
    where statistic.publication_status = 'published'
      and statistic.rate_per_1000 is not null
      and statistic.count_unit is not null
      and statistic.rate_denominator in ('population', 'housing')
      and population.population_band is not null
),
published_reference_percentiles as (
    select
        reference.*,
        (
            rank() over reference_cohort - 1
        )::numeric / nullif(
            count(*) over reference_partition - 1,
            0
        ) as category_percentile
    from published_references reference
    window
        reference_partition as (
            partition by year, population_band, category_code, count_unit, rate_denominator
        ),
        reference_cohort as (
            partition by year, population_band, category_code, count_unit, rate_denominator
            order by rate_per_1000
        )
),
reference_cohort_sizes as (
    select
        year,
        population_band,
        category_code,
        count_unit,
        rate_denominator,
        count(*)::integer as reference_cohort_size
    from published_references
    group by year, population_band, category_code, count_unit, rate_denominator
),
estimated_rate_groups as (
    select distinct
        year,
        population_band,
        category_code,
        count_unit,
        rate_denominator,
        effective_rate_per_1000
    from component_candidates
    where component_source = 'department-masked-average'
      and population_band is not null
),
estimated_percentiles as (
    select
        estimated.year,
        estimated.population_band,
        estimated.category_code,
        estimated.count_unit,
        estimated.rate_denominator,
        estimated.effective_rate_per_1000,
        greatest(
            0::numeric,
            least(
                1::numeric,
                count(reference.rate_per_1000)::numeric
                    / nullif(size.reference_cohort_size - 1, 0)
            )
        ) as category_percentile
    from estimated_rate_groups estimated
    join reference_cohort_sizes size
      on size.year = estimated.year
     and size.population_band = estimated.population_band
     and size.category_code = estimated.category_code
     and size.count_unit = estimated.count_unit
     and size.rate_denominator = estimated.rate_denominator
    left join published_references reference
      on reference.year = estimated.year
     and reference.population_band = estimated.population_band
     and reference.category_code = estimated.category_code
     and reference.count_unit = estimated.count_unit
     and reference.rate_denominator = estimated.rate_denominator
     and reference.rate_per_1000 < estimated.effective_rate_per_1000
    group by
        estimated.year,
        estimated.population_band,
        estimated.category_code,
        estimated.count_unit,
        estimated.rate_denominator,
        estimated.effective_rate_per_1000,
        size.reference_cohort_size
)
select
    candidate.city_insee_code,
    candidate.year,
    candidate.category_code,
    candidate.population,
    candidate.population_year,
    candidate.population_band,
    candidate.availability_bit,
    candidate.count_unit,
    candidate.rate_denominator,
    candidate.component_source,
    candidate.effective_rate_per_1000,
    coalesce(size.reference_cohort_size, 0) as reference_cohort_size,
    case
        when candidate.effective_rate_per_1000 is not null
          and size.reference_cohort_size >= 50
          and candidate.component_source = 'published'
            then published.category_percentile
        when candidate.effective_rate_per_1000 is not null
          and size.reference_cohort_size >= 50
          and candidate.component_source = 'department-masked-average'
            then estimated.category_percentile
        else null
    end as category_percentile
from component_candidates candidate
left join reference_cohort_sizes size
  on size.year = candidate.year
 and size.population_band = candidate.population_band
 and size.category_code = candidate.category_code
 and size.count_unit = candidate.count_unit
 and size.rate_denominator = candidate.rate_denominator
left join published_reference_percentiles published
  on candidate.component_source = 'published'
 and published.city_insee_code = candidate.city_insee_code
 and published.year = candidate.year
 and published.category_code = candidate.category_code
left join estimated_percentiles estimated
  on candidate.component_source = 'department-masked-average'
 and estimated.year = candidate.year
 and estimated.population_band = candidate.population_band
 and estimated.category_code = candidate.category_code
 and estimated.count_unit = candidate.count_unit
 and estimated.rate_denominator = candidate.rate_denominator
 and estimated.effective_rate_per_1000 = candidate.effective_rate_per_1000;

create view city_year_comparative_metrics as
with expected_categories as (
    select year, count(distinct category_id)::integer as total_category_count
    from city_year_category_metrics
    group by year
),
published_categories as (
    select
        city_insee_code,
        year,
        count(category_id) filter (where publication_status = 'published')::integer
            as published_category_count
    from city_year_category_metrics
    group by city_insee_code, year
),
component_summary as (
    select
        component.city_insee_code,
        component.year,
        component.population,
        component.population_year,
        component.population_band,
        coalesce(
            bit_or(component.availability_bit) filter (
                where component.component_source = 'published'
            ),
            0
        )::integer as availability_mask,
        coalesce(
            bit_or(component.availability_bit) filter (
                where component.component_source = 'department-masked-average'
            ),
            0
        )::integer as estimated_availability_mask,
        count(*) filter (where component.component_source = 'published')::integer
            as published_basket_category_count,
        count(*) filter (where component.component_source = 'department-masked-average')::integer
            as estimated_basket_category_count,
        count(*) filter (where component.component_source is not null)::integer
            as effective_basket_category_count,
        count(*) filter (where component.category_percentile is not null)::integer
            as comparable_basket_category_count,
        count(*) filter (
            where component.category_percentile is not null
              and component.component_source = 'published'
        )::integer as comparable_published_category_count,
        count(*) filter (
            where component.category_percentile is not null
              and component.component_source = 'department-masked-average'
        )::integer as comparable_estimated_category_count,
        coalesce(
            min(component.reference_cohort_size) filter (
                where component.category_percentile is not null
            ),
            0
        )::integer as minimum_reference_cohort_size,
        avg(component.category_percentile) filter (
            where component.category_percentile is not null
        ) as average_category_percentile
    from city_year_comparative_components component
    group by
        component.city_insee_code,
        component.year,
        component.population,
        component.population_year,
        component.population_band
),
classified as (
    select
        summary.*,
        coalesce(published.published_category_count, 0) as published_category_count,
        coalesce(expected.total_category_count, 0) as total_category_count,
        case
            when coalesce(expected.total_category_count, 0) > 0
                then coalesce(published.published_category_count, 0)::numeric
                    / expected.total_category_count
            else null
        end as coverage_ratio,
        case
            when summary.population is null or summary.population <= 0
                then 'population-unavailable'
            when summary.effective_basket_category_count < 3
                then 'insufficient-coverage'
            when summary.comparable_basket_category_count < 3
                then 'reference-cohort-too-small'
            else 'comparable'
        end as comparative_index_status
    from component_summary summary
    left join published_categories published
      on published.city_insee_code = summary.city_insee_code
     and published.year = summary.year
    left join expected_categories expected on expected.year = summary.year
)
select
    classified.city_insee_code,
    classified.year,
    classified.population,
    classified.population_year,
    classified.population_band,
    classified.published_category_count,
    classified.total_category_count,
    classified.coverage_ratio,
    classified.availability_mask,
    classified.published_basket_category_count,
    classified.minimum_reference_cohort_size as cohort_size,
    classified.estimated_basket_category_count,
    classified.comparable_basket_category_count,
    classified.estimated_availability_mask,
    classified.minimum_reference_cohort_size,
    case
        when classified.comparative_index_status <> 'comparable' then 'unavailable'
        when classified.comparable_published_category_count > 0
          and classified.comparable_estimated_category_count > 0
            then 'partially-estimated'
        when classified.comparable_estimated_category_count > 0
            then 'estimated-only'
        else 'published-only'
    end as comparative_index_provenance,
    classified.comparative_index_status,
    case
        when classified.comparative_index_status = 'comparable'
            then round(classified.average_category_percentile * 100)::integer
        else null
    end as comparative_index,
    case
        when classified.comparative_index_status <> 'comparable' then null
        when classified.comparable_basket_category_count = 6 then 'high'
        when classified.comparable_basket_category_count >= 4 then 'medium'
        else 'low'
    end as comparative_index_confidence,
    'residential-risk-v2'::text as basket_version
from classified;
