create table if not exists exposure_index_category_anchors (
    category_code text primary key,
    availability_bit smallint not null unique check (availability_bit between 0 and 5),
    calibration_year smallint not null check (calibration_year = 2025),
    rate_denominator text not null check (rate_denominator in ('population', 'housing')),
    count_unit text not null,
    anchor_rate_per_1000 numeric(12, 4) not null check (anchor_rate_per_1000 > 0),
    created_at timestamptz not null default now()
);

alter table exposure_index_category_anchors
    drop constraint if exists exposure_index_category_anchors_category_code_fkey;

insert into exposure_index_category_anchors (
    category_code, availability_bit, calibration_year, rate_denominator, count_unit, anchor_rate_per_1000
)
values
    ('ssmsi-78384436563146dc6167ea53b7b5e0cd', 0, 2025, 'housing', 'Infraction', 16.0470),
    ('ssmsi-74a195792dd119f60822e61df3587522', 1, 2025, 'population', 'Véhicule', 5.1964),
    ('ssmsi-d3e9d2e40d72b8850d5283eb73bdc928', 2, 2025, 'population', 'Véhicule', 13.2453),
    ('ssmsi-bf6b19b3e53b90f6594ec2e8303c5778', 3, 2025, 'population', 'Infraction', 13.8213),
    ('ssmsi-a2601b900aa009440624697e1d74e4a9', 4, 2025, 'population', 'Victime', 8.5257),
    ('ssmsi-bdbeb8ca73503f8264dab16159795328', 5, 2025, 'population', 'Mis en cause', 5.1832)
on conflict (category_code) do update
set availability_bit = excluded.availability_bit,
    calibration_year = excluded.calibration_year,
    rate_denominator = excluded.rate_denominator,
    count_unit = excluded.count_unit,
    anchor_rate_per_1000 = excluded.anchor_rate_per_1000;

alter table search_metrics_city_year_category
    add column if not exists category_exposure_score numeric(8, 4),
    add column if not exists category_exposure_source text;

alter table search_metrics_city_year_comparative
    add column if not exists effective_basket_category_count integer,
    add column if not exists basket_index_coverage numeric,
    add column if not exists low_volume_cap_applied boolean not null default false;

alter table search_metrics_city_year_comparative
    alter column comparative_index type numeric(5, 1)
    using comparative_index::numeric(5, 1);

drop view if exists city_year_comparative_metrics;
drop view if exists city_year_comparative_components;

create view city_year_comparative_components as
with basket as (
    select
        anchor.category_code,
        anchor.availability_bit::integer as availability_bit,
        anchor.rate_denominator,
        anchor.count_unit,
        anchor.anchor_rate_per_1000
    from exposure_index_category_anchors anchor
),
years as (
    select distinct year from city_year_category_metrics
),
city_year_population as (
    select
        city.insee_code as city_insee_code,
        years.year,
        coalesce(population.population, city.reference_population) as population,
        coalesce(population.year, city.population_year) as population_year
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
        basket.category_code,
        basket.availability_bit,
        basket.rate_denominator as anchored_rate_denominator,
        basket.count_unit as anchored_count_unit,
        basket.anchor_rate_per_1000,
        statistic.incident_count,
        statistic.publication_status,
        statistic.count_unit,
        statistic.rate_denominator,
        case
            when statistic.publication_status = 'published'
              and statistic.rate_per_1000 >= 0
              and statistic.count_unit = basket.count_unit
              and statistic.rate_denominator = basket.rate_denominator
                then 'published'
            when statistic.publication_status = 'masked'
              and statistic.complement_info_taux >= 0
              and statistic.count_unit = basket.count_unit
              and statistic.rate_denominator = basket.rate_denominator
                then 'department-masked-average'
            else null
        end as component_source,
        case
            when statistic.publication_status = 'published'
              and statistic.rate_per_1000 >= 0
              and statistic.count_unit = basket.count_unit
              and statistic.rate_denominator = basket.rate_denominator
                then statistic.rate_per_1000
            when statistic.publication_status = 'masked'
              and statistic.complement_info_taux >= 0
              and statistic.count_unit = basket.count_unit
              and statistic.rate_denominator = basket.rate_denominator
                then statistic.complement_info_taux
            else null
        end as effective_rate_per_1000,
        case
            when statistic.publication_status = 'published'
              and statistic.rate_per_1000 >= 0
              and statistic.count_unit = basket.count_unit
              and statistic.rate_denominator = basket.rate_denominator
                then least(100::numeric, statistic.rate_per_1000 / basket.anchor_rate_per_1000 * 100)
            when statistic.publication_status = 'masked'
              and statistic.complement_info_taux >= 0
              and statistic.count_unit = basket.count_unit
              and statistic.rate_denominator = basket.rate_denominator
                then least(100::numeric, statistic.complement_info_taux / basket.anchor_rate_per_1000 * 100)
            else null
        end as component_exposure_score
    from city_year_population city_year
    cross join basket
    left join city_year_category_metrics statistic
      on statistic.city_insee_code = city_year.city_insee_code
     and statistic.year = city_year.year
     and statistic.category_code = basket.category_code
)
select
    candidate.city_insee_code,
    candidate.year,
    candidate.category_code,
    candidate.population,
    candidate.population_year,
    candidate.availability_bit,
    candidate.anchored_rate_denominator,
    candidate.anchored_count_unit,
    candidate.anchor_rate_per_1000,
    candidate.count_unit,
    candidate.rate_denominator,
    candidate.publication_status,
    candidate.incident_count,
    candidate.component_source,
    candidate.effective_rate_per_1000,
    round(candidate.component_exposure_score, 4) as component_exposure_score
from component_candidates candidate;

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
basket_publication as (
    select
        component.city_insee_code,
        component.year,
        count(*) filter (where component.publication_status = 'published')::integer
            as published_basket_record_count
    from city_year_comparative_components component
    group by component.city_insee_code, component.year
),
component_summary as (
    select
        component.city_insee_code,
        component.year,
        component.population,
        component.population_year,
        coalesce(bit_or(1 << component.availability_bit) filter (
            where component.component_source = 'published'
        ), 0)::integer as availability_mask,
        coalesce(bit_or(1 << component.availability_bit) filter (
            where component.component_source = 'department-masked-average'
        ), 0)::integer as estimated_availability_mask,
        count(*) filter (where component.component_source = 'published')::integer
            as published_basket_category_count,
        count(*) filter (where component.component_source = 'department-masked-average')::integer
            as estimated_basket_category_count,
        count(*) filter (where component.component_exposure_score is not null)::integer
            as effective_basket_category_count,
        avg(component.component_exposure_score) as average_exposure_score
    from city_year_comparative_components component
    group by
        component.city_insee_code,
        component.year,
        component.population,
        component.population_year
),
low_volume_summary as (
    select
        component.city_insee_code,
        component.year,
        count(*) filter (
            where component.category_code in (
                'ssmsi-78384436563146dc6167ea53b7b5e0cd',
                'ssmsi-bf6b19b3e53b90f6594ec2e8303c5778'
            )
              and component.publication_status = 'published'
              and component.count_unit = 'Infraction'
              and component.incident_count is not null
        ) = 2 as has_two_published_infraction_counts,
        sum(component.incident_count) filter (
            where component.category_code in (
                'ssmsi-78384436563146dc6167ea53b7b5e0cd',
                'ssmsi-bf6b19b3e53b90f6594ec2e8303c5778'
            )
              and component.publication_status = 'published'
              and component.count_unit = 'Infraction'
              and component.incident_count is not null
        ) as published_infraction_count
    from city_year_comparative_components component
    group by component.city_insee_code, component.year
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
        coalesce(basket_publication.published_basket_record_count, 0) as published_basket_record_count,
        coalesce(low_volume.has_two_published_infraction_counts, false)
          and low_volume.published_infraction_count < 10
          and coalesce(basket_publication.published_basket_record_count, 0) >= 5
            as low_volume_cap_eligible
    from component_summary summary
    left join published_categories published
      on published.city_insee_code = summary.city_insee_code
     and published.year = summary.year
    left join expected_categories expected on expected.year = summary.year
    left join basket_publication
      on basket_publication.city_insee_code = summary.city_insee_code
     and basket_publication.year = summary.year
    left join low_volume_summary low_volume
      on low_volume.city_insee_code = summary.city_insee_code
     and low_volume.year = summary.year
)
select
    classified.city_insee_code,
    classified.year,
    classified.population,
    classified.population_year,
    classified.published_category_count,
    classified.total_category_count,
    classified.coverage_ratio,
    classified.availability_mask,
    classified.estimated_availability_mask,
    classified.published_basket_category_count,
    classified.estimated_basket_category_count,
    classified.effective_basket_category_count,
    classified.effective_basket_category_count::numeric / 6 as basket_index_coverage,
    case
        when classified.effective_basket_category_count = 0 then 'unavailable'
        else 'available'
    end as comparative_index_status,
    case
        when classified.effective_basket_category_count = 0 then 'unavailable'
        when classified.published_basket_category_count > 0
          and classified.estimated_basket_category_count > 0 then 'partially-estimated'
        when classified.estimated_basket_category_count > 0 then 'estimated-only'
        else 'published-only'
    end as comparative_index_provenance,
    case
        when classified.effective_basket_category_count = 0 then null
        when classified.low_volume_cap_eligible and classified.average_exposure_score > 35
            then 35::numeric
        else round(classified.average_exposure_score, 1)
    end as comparative_index,
    coalesce(
        classified.low_volume_cap_eligible
          and classified.average_exposure_score > 35,
        false
    ) as low_volume_cap_applied,
    'absolute-exposure-v1'::text as basket_version
from classified;
