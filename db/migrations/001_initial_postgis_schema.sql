create extension if not exists postgis;
create extension if not exists postgis_topology;

do $$
begin
    create type publication_status as enum ('published', 'masked', 'unknown');
exception
    when duplicate_object then null;
end
$$;

create table if not exists import_batches (
    id bigserial primary key,
    source_system text not null,
    source_url text,
    source_year smallint,
    status text not null default 'completed',
    metadata jsonb not null default '{}'::jsonb,
    started_at timestamptz not null default now(),
    completed_at timestamptz,
    constraint import_batches_status_check
        check (status in ('started', 'completed', 'failed'))
);

create table if not exists regions (
    code varchar(3) primary key,
    name text not null,
    source text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists departments (
    code varchar(3) primary key,
    name text not null,
    region_code varchar(3) not null references regions(code),
    source text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists cities (
    insee_code varchar(5) primary key,
    name text not null,
    department_code varchar(3) not null references departments(code),
    region_code varchar(3) not null references regions(code),
    latitude numeric(9, 6),
    longitude numeric(9, 6),
    geom geography(Point, 4326),
    reference_population integer,
    population_year smallint,
    source text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint cities_latitude_check
        check (latitude is null or latitude between -90 and 90),
    constraint cities_longitude_check
        check (longitude is null or longitude between -180 and 180),
    constraint cities_coordinates_check
        check (
            (latitude is null and longitude is null and geom is null)
            or (latitude is not null and longitude is not null and geom is not null)
        ),
    constraint cities_reference_population_check
        check (reference_population is null or reference_population >= 0),
    constraint cities_population_year_check
        check (population_year is null or population_year between 1800 and 2100)
);

create table if not exists population_history (
    id bigserial primary key,
    city_insee_code varchar(5) not null references cities(insee_code) on delete cascade,
    year smallint not null,
    population integer,
    source text not null,
    import_batch_id bigint references import_batches(id),
    imported_at timestamptz not null default now(),
    constraint population_history_year_check
        check (year between 1800 and 2100),
    constraint population_history_population_check
        check (population is null or population >= 0),
    constraint population_history_city_year_source_key
        unique (city_insee_code, year, source)
);

create table if not exists crime_categories (
    id bigserial primary key,
    code text not null unique,
    label text not null,
    description text,
    source text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists crime_stats (
    id bigserial primary key,
    city_insee_code varchar(5) not null references cities(insee_code) on delete cascade,
    year smallint not null,
    category_id bigint not null references crime_categories(id),
    incident_count integer,
    rate_per_1000 numeric(12, 4),
    publication_status publication_status not null default 'unknown',
    source text not null,
    import_batch_id bigint references import_batches(id),
    imported_at timestamptz not null default now(),
    constraint crime_stats_year_check
        check (year between 2000 and 2100),
    constraint crime_stats_incident_count_check
        check (incident_count is null or incident_count >= 0),
    constraint crime_stats_rate_per_1000_check
        check (rate_per_1000 is null or rate_per_1000 >= 0),
    constraint crime_stats_masked_values_are_null_check
        check (
            publication_status = 'published'
            or (incident_count is null and rate_per_1000 is null)
        ),
    constraint crime_stats_city_year_category_source_key
        unique (city_insee_code, year, category_id, source)
);

create index if not exists departments_region_code_idx
    on departments(region_code);

create index if not exists cities_department_code_idx
    on cities(department_code);

create index if not exists cities_region_code_idx
    on cities(region_code);

create index if not exists cities_geom_gix
    on cities using gist(geom);

create index if not exists population_history_city_year_idx
    on population_history(city_insee_code, year);

create index if not exists crime_stats_year_idx
    on crime_stats(year);

create index if not exists crime_stats_category_year_idx
    on crime_stats(category_id, year);

create index if not exists crime_stats_city_year_idx
    on crime_stats(city_insee_code, year);

create or replace function set_city_geom_from_coordinates()
returns trigger
language plpgsql
as $$
begin
    if new.latitude is null and new.longitude is null then
        new.geom = null;
    elsif new.latitude is not null and new.longitude is not null then
        new.geom = st_setsrid(st_makepoint(new.longitude, new.latitude), 4326)::geography;
    end if;

    return new;
end;
$$;

drop trigger if exists cities_set_geom_from_coordinates on cities;

create trigger cities_set_geom_from_coordinates
before insert or update of latitude, longitude
on cities
for each row
execute function set_city_geom_from_coordinates();
