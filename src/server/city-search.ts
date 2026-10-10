import type { QueryResult, QueryResultRow } from "pg";
import { z } from "zod";

import {
  mapComparativeIndex,
  mapPublishedMetrics,
  type ComparativeIndex,
  type ComparativeIndexColumns,
  type PublishedMetrics,
  type PublishedMetricsColumns
} from "@/server/comparative-index";

export type CitySearchParams = {
  year: number;
  regionCode?: string;
  departmentCode?: string;
  commune?: string;
  populationMin?: number;
  populationMax?: number;
  comparativeIndexMin?: number;
  comparativeIndexMax?: number;
  categoryCode?: string;
  categoryIncidentMin?: number;
  categoryIncidentMax?: number;
  categoryRateMin?: number;
  categoryRateMax?: number;
  sortBy?:
    | "name"
    | "population"
    | "comparativeIndex"
    | "categoryIncidentCount"
    | "categoryRatePer1000";
  sortDirection?: "asc" | "desc";
  sortCategoryCode?: string;
  limit: number;
  offset: number;
};

export type CitySearchRow = {
  inseeCode: string;
  name: string;
  departmentCode: string;
  departmentName: string;
  regionCode: string;
  regionName: string;
  latitude: number | null;
  longitude: number | null;
  population: number | null;
  populationYear: number | null;
  published: PublishedMetrics;
  comparativeIndex: ComparativeIndex;
  categories: Array<{
    code: string;
    label: string;
    incidentCount: number | null;
    ratePer1000: string | null;
    countUnit: string | null;
    rateDenominator: "population" | "housing" | "unknown";
    populationDenominator: number | null;
    populationDenominatorYear: number | null;
    housingDenominator: number | null;
    housingDenominatorYear: number | null;
    publicationStatus: "published" | "masked" | "unknown";
  }>;
};

export type SqlQuery = {
  text: string;
  values: Array<string | number>;
};

const searchParamSchema = z.object({
  year: z.coerce.number().int().min(2000).max(2100),
  regionCode: z.string().trim().min(1).max(3).optional(),
  departmentCode: z.string().trim().min(1).max(3).optional(),
  commune: z.string().trim().min(1).max(120).optional(),
  populationMin: z.coerce.number().int().min(0).optional(),
  populationMax: z.coerce.number().int().min(0).optional(),
  comparativeIndexMin: z.coerce.number().int().min(0).max(100).optional(),
  comparativeIndexMax: z.coerce.number().int().min(0).max(100).optional(),
  categoryCode: z.string().trim().min(1).max(80).optional(),
  categoryIncidentMin: z.coerce.number().int().min(0).optional(),
  categoryIncidentMax: z.coerce.number().int().min(0).optional(),
  categoryRateMin: z.coerce.number().min(0).optional(),
  categoryRateMax: z.coerce.number().min(0).optional(),
  sortBy: z
    .enum([
      "name",
      "population",
      "comparativeIndex",
      "categoryIncidentCount",
      "categoryRatePer1000"
    ])
    .optional(),
  sortDirection: z.enum(["asc", "desc"]).optional(),
  sortCategoryCode: z.string().trim().min(1).max(80).optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(50),
  offset: z.coerce.number().int().min(0).default(0)
}).strict();

export function parseCitySearchParams(params: URLSearchParams): CitySearchParams {
  const raw = Object.fromEntries(params.entries());
  const parsed = searchParamSchema.parse(raw);

  return {
    ...parsed,
    limit: Math.min(parsed.limit, 200)
  };
}

export function buildCitySearchQuery(params: CitySearchParams): SqlQuery {
  const values: Array<string | number> = [params.year];
  const visibleWhere: string[] = [];
  const categoryWhere: string[] = [];

  const pushValue = (value: string | number) => {
    values.push(value);
    return `$${values.length}`;
  };

  if (params.regionCode) {
    visibleWhere.push(`cm.region_code = ${pushValue(params.regionCode)}`);
  }

  if (params.departmentCode) {
    visibleWhere.push(`cm.department_code = ${pushValue(params.departmentCode)}`);
  }

  if (params.commune) {
    visibleWhere.push(`cm.name ilike ${pushValue(`%${params.commune}%`)}`);
  }

  if (params.populationMin !== undefined || params.populationMax !== undefined) {
    visibleWhere.push("cm.population is not null");
  }

  if (params.populationMin !== undefined) {
    visibleWhere.push(`cm.population >= ${pushValue(params.populationMin)}`);
  }

  if (params.populationMax !== undefined) {
    visibleWhere.push(`cm.population <= ${pushValue(params.populationMax)}`);
  }

  if (params.comparativeIndexMin !== undefined) {
    visibleWhere.push(`cm.comparative_index >= ${pushValue(params.comparativeIndexMin)}`);
  }

  if (params.comparativeIndexMax !== undefined) {
    visibleWhere.push(`cm.comparative_index <= ${pushValue(params.comparativeIndexMax)}`);
  }

  if (params.categoryCode) {
    categoryWhere.push(`rc_filter.category_code = ${pushValue(params.categoryCode)}`);

    if (params.categoryIncidentMin !== undefined) {
      categoryWhere.push(`rc_filter.incident_count >= ${pushValue(params.categoryIncidentMin)}`);
    }

    if (params.categoryIncidentMax !== undefined) {
      categoryWhere.push(`rc_filter.incident_count <= ${pushValue(params.categoryIncidentMax)}`);
    }

    if (params.categoryRateMin !== undefined) {
      categoryWhere.push("rc_filter.count_unit is not null and rc_filter.rate_denominator in ('population', 'housing')");
      categoryWhere.push(`rc_filter.rate_per_1000 >= ${pushValue(params.categoryRateMin)}`);
    }

    if (params.categoryRateMax !== undefined) {
      if (params.categoryRateMin === undefined) {
        categoryWhere.push("rc_filter.count_unit is not null and rc_filter.rate_denominator in ('population', 'housing')");
      }
      categoryWhere.push(`rc_filter.rate_per_1000 <= ${pushValue(params.categoryRateMax)}`);
    }

    visibleWhere.push(`
      exists (
        select 1
        from search_metrics_city_year_category rc_filter
        where rc_filter.snapshot_id = cm.snapshot_id
          and rc_filter.city_insee_code = cm.insee_code
          and rc_filter.year = $1
          and rc_filter.publication_status = 'published'
          and ${categoryWhere.join("\n          and ")}
      )
    `);
  }

  const categorySortRequested =
    (params.sortBy === "categoryIncidentCount" || params.sortBy === "categoryRatePer1000") &&
    params.sortCategoryCode !== undefined;
  const categorySortPlaceholder = categorySortRequested
    ? pushValue(params.sortCategoryCode as string)
    : null;

  values.push(params.limit, params.offset);
  const limitPlaceholder = `$${values.length - 1}`;
  const offsetPlaceholder = `$${values.length}`;

  const finalWhere = visibleWhere.length > 0 ? `where ${visibleWhere.join("\n  and ")}` : "";
  const orderBy = buildOrderByClause(params, categorySortRequested);
  const categorySortJoin = categorySortPlaceholder
    ? `left join lateral (
    select
      category.incident_count as sort_category_incident_count,
      case when category.count_unit is not null and category.rate_denominator in ('population', 'housing')
        then category.rate_per_1000 else null end as sort_category_rate_per_1000
    from search_metrics_city_year_category category
    where category.snapshot_id = active_snapshot.snapshot_id
      and category.city_insee_code = c.insee_code
      and category.year = $1
      and category.category_code = ${categorySortPlaceholder}
      and category.publication_status = 'published'
    limit 1
  ) sort_metrics on true`
    : `left join lateral (
    select null::integer as sort_category_incident_count, null::numeric as sort_category_rate_per_1000
  ) sort_metrics on true`;

  return {
    values,
    text: `
with active_snapshot as (
  select snapshot_id
  from search_metrics_active
  where singleton = true
),
city_metrics as (
  select
    active_snapshot.snapshot_id,
    c.insee_code,
    c.name,
    c.department_code,
    d.name as department_name,
    c.region_code,
    r.name as region_name,
    c.latitude,
    c.longitude,
    metrics.population as population,
    metrics.population_year as population_year,
    coalesce(metrics.published_category_count, 0) as published_category_count,
    coalesce(metrics.total_category_count, 0) as total_category_count,
    metrics.coverage_ratio,
    coalesce(metrics.published_basket_category_count, 0) as published_basket_category_count,
    coalesce(metrics.estimated_basket_category_count, 0) as estimated_basket_category_count,
    coalesce(metrics.effective_basket_category_count, 0) as effective_basket_category_count,
    metrics.basket_index_coverage,
    coalesce(metrics.low_volume_cap_applied, false) as low_volume_cap_applied,
    coalesce(metrics.estimated_availability_mask, 0) as estimated_availability_mask,
    coalesce(metrics.comparative_index_provenance, 'unavailable') as comparative_index_provenance,
    metrics.comparative_index,
    metrics.availability_mask,
    coalesce(metrics.comparative_index_status, 'unavailable') as comparative_index_status,
    metrics.basket_version,
    sort_metrics.sort_category_incident_count,
    sort_metrics.sort_category_rate_per_1000
  from active_snapshot
  cross join cities c
  join departments d on d.code = c.department_code
  join regions r on r.code = c.region_code
  left join search_metrics_city_year_comparative metrics
    on metrics.snapshot_id = active_snapshot.snapshot_id
   and metrics.city_insee_code = c.insee_code
   and metrics.year = $1
  ${categorySortJoin}
)
select
  cm.*,
  coalesce(category_data.categories, '[]'::jsonb) as categories
from city_metrics cm
left join lateral (
  select
    jsonb_agg(
      jsonb_build_object(
        'code', rc.category_code,
        'label', rc.category_label,
        'incidentCount', rc.incident_count,
        'ratePer1000', rc.rate_per_1000,
        'countUnit', rc.count_unit,
        'rateDenominator', rc.rate_denominator,
        'populationDenominator', rc.insee_pop,
        'populationDenominatorYear', rc.insee_pop_millesime,
        'housingDenominator', rc.insee_log,
        'housingDenominatorYear', rc.insee_log_millesime,
        'publicationStatus', rc.publication_status
      )
      order by rc.category_label
    ) as categories
  from search_metrics_city_year_category rc
  where rc.snapshot_id = cm.snapshot_id
    and rc.city_insee_code = cm.insee_code
    and rc.year = $1
) category_data on true
${finalWhere}
order by ${orderBy}
limit ${limitPlaceholder}
offset ${offsetPlaceholder}
`.trim()
  };
}

function buildOrderByClause(
  params: CitySearchParams,
  categorySortRequested: boolean
): string {
  const direction = params.sortDirection === "asc" ? "asc" : "desc";
  const fallback = "name asc, insee_code asc";

  switch (params.sortBy) {
    case "population":
      return `population ${direction} nulls last, ${fallback}`;
    case "comparativeIndex":
      return `comparative_index ${direction} nulls last, ${fallback}`;
    case "categoryIncidentCount":
      return categorySortRequested
        ? `sort_category_incident_count ${direction} nulls last, ${fallback}`
        : fallback;
    case "categoryRatePer1000":
      return categorySortRequested
        ? `sort_category_rate_per_1000 ${direction} nulls last, ${fallback}`
        : fallback;
    case "name":
    default:
      return params.sortDirection === "desc" ? "name desc, insee_code asc" : fallback;
  }
}

type Queryable = {
  query<T extends QueryResultRow>(
    text: string,
    values: Array<string | number>
  ): Promise<QueryResult<T>>;
};

type RawCitySearchRow = {
  insee_code: string;
  name: string;
  department_code: string;
  department_name: string;
  region_code: string;
  region_name: string;
  latitude: string | null;
  longitude: string | null;
  population: number | null;
  population_year: number | null;
  published_category_count: number;
  total_category_count: number;
  coverage_ratio: string | null;
  categories: CitySearchRow["categories"];
} & ComparativeIndexColumns & PublishedMetricsColumns;

export async function searchCities(
  db: Queryable,
  params: CitySearchParams
): Promise<CitySearchRow[]> {
  const query = buildCitySearchQuery(params);
  const result = await db.query<RawCitySearchRow>(query.text, query.values);

  return result.rows.map((row) => ({
    inseeCode: row.insee_code,
    name: row.name,
    departmentCode: row.department_code,
    departmentName: row.department_name,
    regionCode: row.region_code,
    regionName: row.region_name,
    latitude: row.latitude === null ? null : Number(row.latitude),
    longitude: row.longitude === null ? null : Number(row.longitude),
    population: row.population,
    populationYear: row.population_year,
    published: mapPublishedMetrics(row),
    comparativeIndex: mapComparativeIndex(row),
    categories: row.categories
  }));
}
