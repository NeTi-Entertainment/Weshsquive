create table property_sale_observations (
    source_system text not null,
    source_year smallint not null,
    mutation_id text not null,
    city_insee_code varchar(5) not null references cities(insee_code) on delete cascade,
    mutation_date date not null,
    mutation_nature text not null,
    property_type text not null,
    sale_value numeric(18, 2) not null,
    built_area numeric(14, 2) not null,
    import_batch_id bigint not null references import_batches(id),
    imported_at timestamptz not null default now(),
    constraint property_sale_observations_pkey
        primary key (source_system, source_year, mutation_id),
    constraint property_sale_year_check check (source_year between 2000 and 2100),
    constraint property_sale_date_year_check check (extract(year from mutation_date) = source_year),
    constraint property_sale_type_check check (property_type in ('apartment', 'house')),
    constraint property_sale_value_check check (sale_value > 0),
    constraint property_sale_area_check check (built_area > 0)
);

create index property_sale_city_year_type_idx
    on property_sale_observations(city_insee_code, source_year, property_type)
    include (sale_value, built_area, import_batch_id);

create table property_rent_observations (
    source_system text not null,
    source_year smallint not null,
    city_insee_code varchar(5) not null references cities(insee_code) on delete cascade,
    property_type text not null,
    estimated_rent_per_m2 numeric(14, 4),
    lower_bound_per_m2 numeric(14, 4),
    upper_bound_per_m2 numeric(14, 4),
    prediction_type text,
    commune_observation_count integer,
    grid_observation_count integer,
    adjusted_r2 numeric(12, 8),
    import_batch_id bigint not null references import_batches(id),
    imported_at timestamptz not null default now(),
    constraint property_rent_observations_pkey
        primary key (source_system, source_year, city_insee_code, property_type),
    constraint property_rent_year_check check (source_year between 2000 and 2100),
    constraint property_rent_type_check check (property_type in ('apartment', 'house')),
    constraint property_rent_commune_count_check
        check (commune_observation_count is null or commune_observation_count >= 0),
    constraint property_rent_grid_count_check
        check (grid_observation_count is null or grid_observation_count >= 0)
);

create index property_rent_city_year_type_idx
    on property_rent_observations(city_insee_code, source_year, property_type)
    include (
        estimated_rent_per_m2, lower_bound_per_m2, upper_bound_per_m2,
        prediction_type, commune_observation_count, adjusted_r2, import_batch_id
    );

create table property_market_metrics (
    city_insee_code varchar(5) not null references cities(insee_code) on delete cascade,
    year smallint not null,
    metric_kind text not null,
    property_type text not null,
    value_per_m2 numeric(14, 4),
    lower_bound_per_m2 numeric(14, 4),
    upper_bound_per_m2 numeric(14, 4),
    sample_count integer,
    national_percentile numeric(12, 10),
    display_status text not null,
    source_system text not null,
    import_batch_id bigint references import_batches(id),
    calculated_at timestamptz not null default now(),
    constraint property_market_metrics_pkey
        primary key (city_insee_code, year, metric_kind, property_type),
    constraint property_market_year_check check (year between 2000 and 2100),
    constraint property_market_metric_type_check check (
        (metric_kind = 'sale' and property_type in ('all', 'apartment', 'house'))
        or (metric_kind = 'rent' and property_type in ('apartment', 'house'))
    ),
    constraint property_market_sample_count_check check (sample_count is null or sample_count >= 0),
    constraint property_market_percentile_check
        check (national_percentile is null or national_percentile between 0 and 1),
    constraint property_market_status_check check (
        display_status in (
            'published', 'source-uncovered', 'no-data', 'insufficient-sample',
            'non-communal-estimate', 'insufficient-quality', 'invalid-value'
        )
    ),
    constraint property_market_publication_check check (
        (
            display_status = 'published'
            and value_per_m2 is not null
            and national_percentile is not null
        )
        or (
            display_status <> 'published'
            and value_per_m2 is null
            and national_percentile is null
        )
    )
);

create index property_market_lookup_idx
    on property_market_metrics(year, metric_kind, property_type, city_insee_code)
    include (
        value_per_m2, lower_bound_per_m2, upper_bound_per_m2,
        sample_count, national_percentile, display_status, source_system,
        import_batch_id
    );

create or replace function refresh_property_market_metrics(target_year smallint)
returns void
language plpgsql
as $$
declare
    sale_batch_id bigint;
    rent_batch_id bigint;
begin
    if target_year < 2000 or target_year > 2100 then
        raise exception 'Invalid property market year: %', target_year;
    end if;

    select id into sale_batch_id
    from import_batches
    where source_system = 'dvf-geolocated'
      and source_year = target_year
      and status = 'completed'
    order by completed_at desc nulls last, id desc
    limit 1;

    select id into rent_batch_id
    from import_batches
    where source_system = 'anil-rent-map'
      and source_year = target_year
      and status = 'completed'
    order by completed_at desc nulls last, id desc
    limit 1;

    delete from property_market_metrics where year = target_year;

    if sale_batch_id is not null then
        with raw_counts as (
            select
                observation.city_insee_code,
                kind.property_type,
                count(*)::integer as raw_count
            from property_sale_observations observation
            cross join lateral (
                values (observation.property_type), ('all'::text)
            ) kind(property_type)
            where observation.source_system = 'dvf-geolocated'
              and observation.source_year = target_year
            group by observation.city_insee_code, kind.property_type
        ),
        valid_values as (
            select
                observation.city_insee_code,
                kind.property_type,
                observation.sale_value / observation.built_area as price_per_m2
            from property_sale_observations observation
            cross join lateral (
                values (observation.property_type), ('all'::text)
            ) kind(property_type)
            where observation.source_system = 'dvf-geolocated'
              and observation.source_year = target_year
              and observation.sale_value / observation.built_area <= 100000
        ),
        aggregates as (
            select
                city_insee_code,
                property_type,
                count(*)::integer as sample_count,
                percentile_cont(0.5) within group (order by price_per_m2)::numeric(14, 4) as median_price
            from valid_values
            group by city_insee_code, property_type
        ),
        candidates as (
            select
                city.insee_code as city_insee_code,
                target_year as year,
                property_type.property_type,
                aggregate.sample_count,
                case
                    when city.department_code in ('57', '67', '68', '976') then 'source-uncovered'
                    when aggregate.sample_count >= 5 then 'published'
                    when aggregate.sample_count between 1 and 4 then 'insufficient-sample'
                    when coalesce(raw_count.raw_count, 0) > 0 then 'invalid-value'
                    else 'no-data'
                end as display_status,
                case
                    when city.department_code not in ('57', '67', '68', '976')
                     and aggregate.sample_count >= 5
                    then aggregate.median_price
                    else null
                end as value_per_m2
            from cities city
            cross join (values ('all'::text), ('apartment'::text), ('house'::text)) property_type(property_type)
            left join aggregates aggregate
              on aggregate.city_insee_code = city.insee_code
             and aggregate.property_type = property_type.property_type
            left join raw_counts raw_count
              on raw_count.city_insee_code = city.insee_code
             and raw_count.property_type = property_type.property_type
        ),
        published_percentiles as (
            select
                city_insee_code,
                property_type,
                percent_rank() over (
                    partition by property_type
                    order by value_per_m2
                )::numeric(12, 10) as national_percentile
            from candidates
            where display_status = 'published'
        )
        insert into property_market_metrics (
            city_insee_code, year, metric_kind, property_type, value_per_m2,
            sample_count, national_percentile, display_status, source_system,
            import_batch_id
        )
        select
            candidate.city_insee_code,
            candidate.year,
            'sale',
            candidate.property_type,
            candidate.value_per_m2,
            candidate.sample_count,
            percentile.national_percentile,
            candidate.display_status,
            'dvf-geolocated',
            sale_batch_id
        from candidates candidate
        left join published_percentiles percentile
          on percentile.city_insee_code = candidate.city_insee_code
         and percentile.property_type = candidate.property_type;
    end if;

    if rent_batch_id is not null then
        with candidates as (
            select
                city.insee_code as city_insee_code,
                target_year as year,
                property_type.property_type,
                observation.estimated_rent_per_m2,
                observation.lower_bound_per_m2,
                observation.upper_bound_per_m2,
                observation.commune_observation_count,
                case
                    when city.department_code = '976' then 'source-uncovered'
                    when observation.city_insee_code is null then 'no-data'
                    when observation.prediction_type is distinct from 'commune' then 'non-communal-estimate'
                    when observation.estimated_rent_per_m2 is null
                      or observation.estimated_rent_per_m2 <= 0
                      or observation.lower_bound_per_m2 is null
                      or observation.lower_bound_per_m2 <= 0
                      or observation.upper_bound_per_m2 is null
                      or observation.upper_bound_per_m2 <= 0
                      or observation.lower_bound_per_m2 > observation.estimated_rent_per_m2
                      or observation.estimated_rent_per_m2 > observation.upper_bound_per_m2
                    then 'invalid-value'
                    when observation.commune_observation_count is null
                      or observation.commune_observation_count < 30
                      or observation.adjusted_r2 is null
                      or observation.adjusted_r2 < 0.5
                    then 'insufficient-quality'
                    else 'published'
                end as display_status
            from cities city
            cross join (values ('apartment'::text), ('house'::text)) property_type(property_type)
            left join property_rent_observations observation
              on observation.city_insee_code = city.insee_code
             and observation.source_system = 'anil-rent-map'
             and observation.source_year = target_year
             and observation.property_type = property_type.property_type
        ),
        displayable as (
            select
                *,
                case when display_status = 'published' then estimated_rent_per_m2 else null end as value_per_m2
            from candidates
        ),
        published_percentiles as (
            select
                city_insee_code,
                property_type,
                percent_rank() over (
                    partition by property_type
                    order by value_per_m2
                )::numeric(12, 10) as national_percentile
            from displayable
            where display_status = 'published'
        )
        insert into property_market_metrics (
            city_insee_code, year, metric_kind, property_type, value_per_m2,
            lower_bound_per_m2, upper_bound_per_m2, sample_count,
            national_percentile, display_status, source_system, import_batch_id
        )
        select
            candidate.city_insee_code,
            candidate.year,
            'rent',
            candidate.property_type,
            candidate.value_per_m2,
            case when candidate.display_status = 'published' then candidate.lower_bound_per_m2 else null end,
            case when candidate.display_status = 'published' then candidate.upper_bound_per_m2 else null end,
            candidate.commune_observation_count,
            percentile.national_percentile,
            candidate.display_status,
            'anil-rent-map',
            rent_batch_id
        from displayable candidate
        left join published_percentiles percentile
          on percentile.city_insee_code = candidate.city_insee_code
         and percentile.property_type = candidate.property_type;
    end if;
end;
$$;
