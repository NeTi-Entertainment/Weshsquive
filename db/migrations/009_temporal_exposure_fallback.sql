alter table search_metrics_city_year_category
    add column if not exists category_exposure_source_year smallint,
    add column if not exists category_exposure_rate_per_1000 numeric(18, 6);

alter table search_metrics_city_year_comparative
    add column if not exists historical_published_basket_category_count integer,
    add column if not exists historical_availability_mask integer,
    add column if not exists oldest_exposure_source_year smallint;

drop view if exists city_year_comparative_metrics;
drop view if exists city_year_comparative_components;

create view city_year_comparative_components as
with basket as (
    select
        anchor.category_code,
        anchor.availability_bit::integer as availability_bit,
        anchor.rate_denominator as anchored_rate_denominator,
        anchor.count_unit as anchored_count_unit,
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
target_components as (
    select
        city_year.city_insee_code,
        city_year.year,
        city_year.population,
        city_year.population_year,
        basket.category_code,
        basket.availability_bit,
        basket.anchored_rate_denominator,
        basket.anchored_count_unit,
        basket.anchor_rate_per_1000,
        target.incident_count,
        target.publication_status,
        target.count_unit,
        target.rate_denominator,
        target.complement_info_taux,
        published.source_year as published_source_year,
        published.rate_per_1000 as published_rate_per_1000
    from city_year_population city_year
    cross join basket
    left join city_year_category_metrics target
      on target.city_insee_code = city_year.city_insee_code
     and target.year = city_year.year
     and target.category_code = basket.category_code
    left join lateral (
        select
            observation.year as source_year,
            observation.rate_per_1000
        from city_year_category_metrics observation
        where observation.city_insee_code = city_year.city_insee_code
          and observation.category_code = basket.category_code
          and observation.year between city_year.year - 3 and city_year.year
          and observation.publication_status = 'published'
          and observation.rate_per_1000 is not null
          and observation.rate_per_1000 >= 0
          and observation.count_unit = basket.anchored_count_unit
          and observation.rate_denominator = basket.anchored_rate_denominator
        order by observation.year desc
        limit 1
    ) published on true
),
effective_components as (
    select
        target.*,
        case
            when target.published_source_year = target.year then target.year
            when target.published_source_year is not null then target.published_source_year
            when target.publication_status = 'masked'
              and target.complement_info_taux is not null
              and target.complement_info_taux >= 0
              and target.count_unit = target.anchored_count_unit
              and target.rate_denominator = target.anchored_rate_denominator
                then target.year
            else null
        end as source_year,
        case
            when target.published_source_year = target.year then 'current-published'
            when target.published_source_year is not null then 'historical-published'
            when target.publication_status = 'masked'
              and target.complement_info_taux is not null
              and target.complement_info_taux >= 0
              and target.count_unit = target.anchored_count_unit
              and target.rate_denominator = target.anchored_rate_denominator
                then 'department-masked-average'
            else 'unavailable'
        end as component_source,
        case
            when target.published_source_year is not null then target.published_rate_per_1000
            when target.publication_status = 'masked'
              and target.complement_info_taux is not null
              and target.complement_info_taux >= 0
              and target.count_unit = target.anchored_count_unit
              and target.rate_denominator = target.anchored_rate_denominator
                then target.complement_info_taux
            else null
        end as effective_rate_per_1000
    from target_components target
)
select
    component.city_insee_code,
    component.year,
    component.category_code,
    component.population,
    component.population_year,
    component.availability_bit,
    component.anchored_rate_denominator,
    component.anchored_count_unit,
    component.anchor_rate_per_1000,
    component.count_unit,
    component.rate_denominator,
    component.publication_status,
    component.incident_count,
    component.source_year,
    component.component_source,
    component.effective_rate_per_1000,
    case
        when component.effective_rate_per_1000 is null then null
        else round(
            least(100::numeric, component.effective_rate_per_1000 / component.anchor_rate_per_1000 * 100),
            4
        )
    end as component_exposure_score
from effective_components component;

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
        coalesce(bit_or(1 << component.availability_bit) filter (
            where component.component_source = 'current-published'
        ), 0)::integer as availability_mask,
        coalesce(bit_or(1 << component.availability_bit) filter (
            where component.component_source = 'department-masked-average'
        ), 0)::integer as estimated_availability_mask,
        coalesce(bit_or(1 << component.availability_bit) filter (
            where component.component_source = 'historical-published'
        ), 0)::integer as historical_availability_mask,
        count(*) filter (where component.component_source = 'current-published')::integer
            as published_basket_category_count,
        count(*) filter (where component.component_source = 'historical-published')::integer
            as historical_published_basket_category_count,
        count(*) filter (where component.component_source = 'department-masked-average')::integer
            as estimated_basket_category_count,
        count(*) filter (where component.component_exposure_score is not null)::integer
            as effective_basket_category_count,
        min(component.source_year) filter (where component.component_exposure_score is not null)
            as oldest_exposure_source_year,
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
        ) as published_infraction_count,
        count(*) filter (where component.publication_status = 'published')::integer
            as target_year_published_basket_count
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
        coalesce(low_volume.has_two_published_infraction_counts, false)
          and low_volume.published_infraction_count < 10
          and low_volume.target_year_published_basket_count >= 5
            as low_volume_cap_eligible
    from component_summary summary
    left join published_categories published
      on published.city_insee_code = summary.city_insee_code
     and published.year = summary.year
    left join expected_categories expected on expected.year = summary.year
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
    classified.historical_availability_mask,
    classified.published_basket_category_count,
    classified.historical_published_basket_category_count,
    classified.estimated_basket_category_count,
    classified.effective_basket_category_count,
    classified.effective_basket_category_count::numeric / 6 as basket_index_coverage,
    classified.oldest_exposure_source_year,
    case
        when classified.effective_basket_category_count < 3 then 'unavailable'
        else 'available'
    end as comparative_index_status,
    case
        when classified.effective_basket_category_count < 3 then 'unavailable'
        when classified.estimated_basket_category_count = 0
          and classified.historical_published_basket_category_count = 0 then 'published-only'
        when classified.estimated_basket_category_count = 0 then 'historical-published'
        when classified.published_basket_category_count + classified.historical_published_basket_category_count > 0
            then 'partially-estimated'
        else 'estimated-only'
    end as comparative_index_provenance,
    case
        when classified.effective_basket_category_count < 3 then null
        when classified.low_volume_cap_eligible and classified.average_exposure_score > 35
            then 35::numeric
        else round(classified.average_exposure_score, 1)
    end as comparative_index,
    coalesce(
        classified.low_volume_cap_eligible
          and classified.average_exposure_score > 35,
        false
    ) as low_volume_cap_applied,
    'absolute-exposure-v2'::text as basket_version
from classified;
