alter table cities
    add column if not exists boundary_geom geometry(MultiPolygon, 4326);

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'cities_boundary_geom_valid_check'
          and conrelid = 'cities'::regclass
    ) then
        alter table cities
            add constraint cities_boundary_geom_valid_check
            check (
                boundary_geom is null
                or (not st_isempty(boundary_geom) and st_isvalid(boundary_geom))
            );
    end if;
end
$$;

create index if not exists cities_boundary_geom_gix
    on cities using gist (boundary_geom);
