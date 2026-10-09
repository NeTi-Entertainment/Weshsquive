create table search_metric_snapshots (
    snapshot_id bigint generated always as identity primary key,
    created_at timestamptz not null default now()
);

create table search_metrics_active (
    singleton boolean primary key default true check (singleton),
    snapshot_id bigint not null references search_metric_snapshots(snapshot_id)
);

create table search_metrics_city_year_category (
    snapshot_id bigint not null references search_metric_snapshots(snapshot_id) on delete cascade,
    city_insee_code varchar(5) not null,
    year smallint not null,
    category_id bigint not null,
    category_code text not null,
    category_label text not null,
    incident_count integer,
    rate_per_1000 numeric(12, 4),
    publication_status publication_status not null,
    source text not null,
    imported_at timestamptz not null,
    count_unit text,
    rate_denominator_reference text not null,
    rate_denominator text not null,
    insee_pop bigint,
    insee_pop_millesime smallint,
    insee_log bigint,
    insee_log_millesime smallint,
    primary key (snapshot_id, city_insee_code, year, category_id)
);

create index search_metrics_category_lookup_idx
    on search_metrics_city_year_category(snapshot_id, year, category_code, city_insee_code)
    include (
        category_id, category_label, incident_count, rate_per_1000,
        publication_status, count_unit, rate_denominator,
        insee_pop, insee_pop_millesime, insee_log, insee_log_millesime
    );

create table search_metrics_city_year_comparative (
    snapshot_id bigint not null references search_metric_snapshots(snapshot_id) on delete cascade,
    city_insee_code varchar(5) not null,
    year smallint not null,
    population integer,
    population_year smallint,
    population_band text,
    published_category_count integer,
    total_category_count integer,
    coverage_ratio numeric,
    availability_mask integer,
    published_basket_category_count integer,
    cohort_size integer,
    comparative_index_status text not null,
    comparative_index integer,
    comparative_index_confidence text,
    basket_version text not null,
    primary key (snapshot_id, city_insee_code, year)
);

create index search_metrics_comparative_year_lookup_idx
    on search_metrics_city_year_comparative(snapshot_id, year, city_insee_code);
