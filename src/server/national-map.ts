import type { QueryResult, QueryResultRow } from "pg";
import { z } from "zod";

import {
  mapComparativeIndex,
  mapPublishedMetrics,
  type ComparativeIndexColumns,
  type PublishedMetricsColumns
} from "@/server/comparative-index";
import {
  buildMapEnvironmentalRiskQuery,
  summarizeEnvironmentalRisk,
  type EnvironmentalNeighborRow,
  type EnvironmentalRadiusKm,
  type EnvironmentalRiskSummary
} from "@/server/environmental-risk";
import {
  buildPropertyMarketSelection,
  mapPropertyMarketMetric,
  PROPERTY_MARKET_SELECT_COLUMNS,
  type RawPropertyMarketColumns
} from "@/server/property-market";
import {
  getNationalMapLevel,
  type NationalMapLevel
} from "@/shared/map-levels";
import type {
  PropertyMarketMetric,
  PropertyMarketPropertyType,
  PropertyMarketSelection
} from "@/shared/property-market";

export { getNationalMapLevel } from "@/shared/map-levels";

export type NationalMapParams = {
  year: number;
  zoom: number;
  west: number;
  south: number;
  east: number;
  north: number;
  level: NationalMapLevel;
  criterion: "comparativeIndex" | "categoryRate" | "environmentalRisk" | "salePrice" | "rentPrice";
  mapCategoryCode?: string;
  environmentalRadiusKm?: 25 | 50 | 100 | 200;
  marketPropertyType?: PropertyMarketPropertyType;
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
};

export type NationalMapGroup = {
  type: "region" | "department";
  code: string;
  name: string;
  parentCode: string | null;
  parentName: string | null;
  latitude: number;
  longitude: number;
  communeCount: number;
  bounds: { west: number; south: number; east: number; north: number };
};

export type NationalMapPoint = {
  inseeCode: string;
  name: string;
  departmentCode: string;
  departmentName: string;
  regionCode: string;
  regionName: string;
  latitude: number;
  longitude: number;
  population: number | null;
  populationYear: number | null;
  published: ReturnType<typeof mapPublishedMetrics>;
  comparativeIndex: number | null;
  comparativeIndexStatus: string;
  comparativeIndexCompleteness: "high" | "medium" | "low" | null;
  categoryLabel: string | null;
  categoryIncidentCount: number | null;
  categoryRatePer1000: string | null;
  categoryPercentile: string | null;
  categoryCountUnit: string | null;
  categoryRateDenominator: "population" | "housing" | "unknown";
  categoryPopulationDenominator: number | null;
  categoryPopulationDenominatorYear: number | null;
  categoryHousingDenominator: number | null;
  categoryHousingDenominatorYear: number | null;
  categoryPublicationStatus: "published" | "masked" | "unknown" | null;
  environmentalRisk: EnvironmentalRiskSummary | null;
  propertyMarket: PropertyMarketMetric | null;
};

export type NationalMapResult =
  | { level: "region" | "department"; snapshotId: string | null; groups: NationalMapGroup[]; points: [] }
  | { level: "commune"; snapshotId: string | null; groups: []; points: NationalMapPoint[] };

export type SqlQuery = { text: string; values: Array<string | number> };

const mapParamSchema = z.object({
  year: z.coerce.number().int().min(2000).max(2100),
  zoom: z.coerce.number().min(0).max(22),
  west: z.coerce.number().min(-180).max(180),
  south: z.coerce.number().min(-90).max(90),
  east: z.coerce.number().min(-180).max(180),
  north: z.coerce.number().min(-90).max(90),
  criterion: z.enum(["comparativeIndex", "categoryRate", "environmentalRisk", "salePrice", "rentPrice"]),
  mapCategoryCode: z.string().trim().min(1).max(80).optional(),
  environmentalRadiusKm: z.coerce
    .number()
    .refine((radius): radius is 25 | 50 | 100 | 200 => [25, 50, 100, 200].includes(radius))
    .optional(),
  marketPropertyType: z.enum(["all", "apartment", "house"]).optional(),
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
  categoryRateMax: z.coerce.number().min(0).optional()
}).strict().superRefine((params, context) => {
  if (params.west >= params.east) {
    context.addIssue({ code: "custom", path: ["west"], message: "west must be less than east" });
  }
  if (params.south >= params.north) {
    context.addIssue({ code: "custom", path: ["south"], message: "south must be less than north" });
  }
  if (params.criterion === "categoryRate" && !params.mapCategoryCode) {
    context.addIssue({ code: "custom", path: ["mapCategoryCode"], message: "A map category is required" });
  }
  if (params.criterion === "environmentalRisk" && params.environmentalRadiusKm === undefined) {
    context.addIssue({ code: "custom", path: ["environmentalRadiusKm"], message: "An environmental radius is required" });
  }
  const isPropertyMarket = params.criterion === "salePrice" || params.criterion === "rentPrice";
  if (isPropertyMarket && params.marketPropertyType === undefined) {
    context.addIssue({ code: "custom", path: ["marketPropertyType"], message: "A property type is required" });
  }
  if (params.criterion === "rentPrice" && params.marketPropertyType === "all") {
    context.addIssue({ code: "custom", path: ["marketPropertyType"], message: "Rental layers require apartment or house" });
  }
  if (!isPropertyMarket && params.marketPropertyType !== undefined) {
    context.addIssue({ code: "custom", path: ["marketPropertyType"], message: "Property type is only valid for a property market layer" });
  }
});

export function parseNationalMapParams(params: URLSearchParams): NationalMapParams {
  const parsed = mapParamSchema.parse(Object.fromEntries(params.entries()));
  const zoomLevel = getNationalMapLevel(parsed.zoom);
  return {
    ...parsed,
    level: parsed.departmentCode && zoomLevel !== "commune" ? "department" : zoomLevel
  };
}

export function buildNationalMapQuery(params: NationalMapParams): SqlQuery {
  const values: Array<string | number> = [];
  const pushValue = (value: string | number) => {
    values.push(value);
    return `$${values.length}`;
  };

  if (params.level !== "commune") {
    const navigationFilters = [
      "c.longitude is not null",
      "c.latitude is not null"
    ];
    if (!params.regionCode && !params.departmentCode) {
      const west = pushValue(params.west);
      const south = pushValue(params.south);
      const east = pushValue(params.east);
      const north = pushValue(params.north);
      navigationFilters.unshift(
        `c.longitude between ${west} and ${east}`,
        `c.latitude between ${south} and ${north}`
      );
    }
    if (params.regionCode) navigationFilters.push(`c.region_code = ${pushValue(params.regionCode)}`);
    if (params.departmentCode) navigationFilters.push(`c.department_code = ${pushValue(params.departmentCode)}`);

    const fields = params.level === "region"
      ? {
          key: "region_code",
          code: "visible_groups.code",
          name: "r.name",
          parentCode: "null::text",
          parentName: "null::text",
          regionJoin: "regions r on r.code = territory_bounds.code",
          departmentJoin: "",
          groupBy: ""
        }
      : {
          key: "department_code",
          code: "visible_groups.code",
          name: "d.name",
          parentCode: "territory_bounds.region_code",
          parentName: "r.name",
          regionJoin: "regions r on r.code = territory_bounds.region_code",
          departmentJoin: "join departments d on d.code = territory_bounds.code",
          groupBy: ""
        };
    return {
      values,
      text: `
with visible_cities as (
  select c.${fields.key} as code, c.region_code, c.latitude, c.longitude
  from cities c
  where ${navigationFilters.join("\n    and ")}
), visible_groups as (
  select distinct code from visible_cities
), visible_centers as (
  select code, avg(latitude) as latitude, avg(longitude) as longitude
  from visible_cities
  group by code
), territory_bounds as (
  select
    c.${fields.key} as code,
    c.region_code,
    count(*)::integer as commune_count,
    min(c.longitude) as west,
    min(c.latitude) as south,
    max(c.longitude) as east,
    max(c.latitude) as north
  from cities c
  join visible_groups on visible_groups.code = c.${fields.key}
  where c.longitude is not null and c.latitude is not null
  group by c.${fields.key}, c.region_code
)
select
  (select snapshot_id::text from search_metrics_active where singleton = true) as snapshot_id,
  '${params.level}'::text as level,
  ${fields.code} as code,
  ${fields.name} as name,
  ${fields.parentCode} as parent_code,
  ${fields.parentName} as parent_name,
  visible_centers.latitude,
  visible_centers.longitude,
  territory_bounds.commune_count,
  territory_bounds.west,
  territory_bounds.south,
  territory_bounds.east,
  territory_bounds.north
from visible_groups
join visible_centers on visible_centers.code = visible_groups.code
join territory_bounds on territory_bounds.code = visible_groups.code
join ${fields.regionJoin}
${fields.departmentJoin}
order by name, code
`.trim()
    };
  }

  const valuesWithViewport = [params.west, params.south, params.east, params.north];
  values.push(...valuesWithViewport);
  const visibleFilters = [
    "c.longitude between $1 and $3",
    "c.latitude between $2 and $4",
    "c.longitude is not null",
    "c.latitude is not null"
  ];
  if (params.regionCode) visibleFilters.push(`c.region_code = ${pushValue(params.regionCode)}`);
  if (params.departmentCode) visibleFilters.push(`c.department_code = ${pushValue(params.departmentCode)}`);

  values.push(params.year);
  const yearPlaceholder = `$${values.length}`;
  const mapCategoryPlaceholder = params.criterion === "categoryRate" && params.mapCategoryCode
    ? pushValue(params.mapCategoryCode)
    : null;
  const propertyMarketSelection: PropertyMarketSelection | null = params.criterion === "salePrice" && params.marketPropertyType
    ? { kind: "sale", propertyType: params.marketPropertyType }
    : params.criterion === "rentPrice" && params.marketPropertyType !== "all" && params.marketPropertyType
      ? { kind: "rent", propertyType: params.marketPropertyType }
      : null;
  const propertyMarketKindPlaceholder = propertyMarketSelection
    ? pushValue(propertyMarketSelection.kind)
    : null;
  const propertyMarketTypePlaceholder = propertyMarketSelection
    ? pushValue(propertyMarketSelection.propertyType)
    : null;
  const cityFilters: string[] = [];
  if (params.commune) cityFilters.push(`c.name ilike ${pushValue(`%${params.commune}%`)}`);
  if (params.populationMin !== undefined || params.populationMax !== undefined) {
    cityFilters.push("metrics.population is not null");
  }
  if (params.populationMin !== undefined) cityFilters.push(`metrics.population >= ${pushValue(params.populationMin)}`);
  if (params.populationMax !== undefined) cityFilters.push(`metrics.population <= ${pushValue(params.populationMax)}`);
  if (params.comparativeIndexMin !== undefined) cityFilters.push(`metrics.comparative_index >= ${pushValue(params.comparativeIndexMin)}`);
  if (params.comparativeIndexMax !== undefined) cityFilters.push(`metrics.comparative_index <= ${pushValue(params.comparativeIndexMax)}`);

  if (params.categoryCode) {
    const categoryFilters = [
      "category_filter.snapshot_id = active_snapshot.snapshot_id",
      "category_filter.city_insee_code = c.insee_code",
      `category_filter.year = ${yearPlaceholder}`,
      `category_filter.category_code = ${pushValue(params.categoryCode)}`,
      "category_filter.publication_status = 'published'"
    ];
    if (params.categoryIncidentMin !== undefined) {
      categoryFilters.push(`category_filter.incident_count >= ${pushValue(params.categoryIncidentMin)}`);
    }
    if (params.categoryIncidentMax !== undefined) {
      categoryFilters.push(`category_filter.incident_count <= ${pushValue(params.categoryIncidentMax)}`);
    }
    if (params.categoryRateMin !== undefined || params.categoryRateMax !== undefined) {
      categoryFilters.push("category_filter.count_unit is not null and category_filter.rate_denominator in ('population', 'housing')");
    }
    if (params.categoryRateMin !== undefined) {
      categoryFilters.push(`category_filter.rate_per_1000 >= ${pushValue(params.categoryRateMin)}`);
    }
    if (params.categoryRateMax !== undefined) {
      categoryFilters.push(`category_filter.rate_per_1000 <= ${pushValue(params.categoryRateMax)}`);
    }
    cityFilters.push(`exists (
      select 1 from search_metrics_city_year_category category_filter
      where ${categoryFilters.join("\n        and ")}
    )`);
  }

  const mapCategoryCtes = mapCategoryPlaceholder
    ? `,
map_category_rates as (
  select
    category.city_insee_code,
    metrics.population_band,
    category.count_unit,
    category.rate_denominator,
    category.rate_per_1000,
    percent_rank() over (
      partition by metrics.population_band, category.count_unit, category.rate_denominator
      order by category.rate_per_1000
    ) as category_percentile
  from active_snapshot
  join search_metrics_city_year_category category
    on category.snapshot_id = active_snapshot.snapshot_id
   and category.year = ${yearPlaceholder}
   and category.category_code = ${mapCategoryPlaceholder}
  join search_metrics_city_year_comparative metrics
    on metrics.snapshot_id = active_snapshot.snapshot_id
   and metrics.city_insee_code = category.city_insee_code
   and metrics.year = category.year
  where category.publication_status = 'published'
    and category.rate_per_1000 is not null
    and category.count_unit is not null
    and category.rate_denominator in ('population', 'housing')
    and metrics.population_band is not null
)`
    : "";
  const mapCategoryJoin = mapCategoryPlaceholder
    ? `left join search_metrics_city_year_category map_category
    on map_category.snapshot_id = active_snapshot.snapshot_id
   and map_category.city_insee_code = c.insee_code
   and map_category.year = ${yearPlaceholder}
   and map_category.category_code = ${mapCategoryPlaceholder}
  left join map_category_rates map_percentile
    on map_percentile.city_insee_code = c.insee_code`
    : `left join lateral (
    select null::text as category_label,
      null::integer as incident_count,
      null::numeric as rate_per_1000,
      null::text as count_unit,
      'unknown'::text as rate_denominator,
      null::bigint as insee_pop,
      null::smallint as insee_pop_millesime,
      null::bigint as insee_log,
      null::smallint as insee_log_millesime,
      null::text as publication_status
  ) map_category on true
  left join lateral (
    select null::numeric as category_percentile
  ) map_percentile on true`;
  const propertyMarketJoin = propertyMarketSelection && propertyMarketKindPlaceholder && propertyMarketTypePlaceholder
    ? buildPropertyMarketSelection({
        yearPlaceholder,
        kindPlaceholder: propertyMarketKindPlaceholder,
        propertyTypePlaceholder: propertyMarketTypePlaceholder
      })
    : `left join lateral (
    select
      null::smallint as year,
      null::text as metric_kind,
      null::text as property_type,
      null::numeric as value_per_m2,
      null::numeric as lower_bound_per_m2,
      null::numeric as upper_bound_per_m2,
      null::integer as sample_count,
      null::numeric as national_percentile,
      null::text as display_status,
      null::text as source_system
  ) property_market on true
  left join lateral (
    select false as year_available
  ) property_market_availability on true`;

  return {
    values,
    text: `
with active_snapshot as (
  select snapshot_id from search_metrics_active where singleton = true
)${mapCategoryCtes}
select
  active_snapshot.snapshot_id::text as snapshot_id,
  c.insee_code,
  c.name,
  c.department_code,
  d.name as department_name,
  c.region_code,
  r.name as region_name,
  c.latitude,
  c.longitude,
  metrics.population,
  metrics.population_year,
  metrics.published_category_count,
  metrics.total_category_count,
  metrics.coverage_ratio,
  metrics.comparative_index,
  coalesce(
    metrics.comparative_index_status,
    case when metrics.population is null or metrics.population <= 0
      then 'population-unavailable' else 'insufficient-coverage' end
  ) as comparative_index_status,
  metrics.comparative_index_confidence,
  coalesce(metrics.basket_version, 'residential-risk-v1') as basket_version,
  coalesce(metrics.published_basket_category_count, 0) as published_basket_category_count,
  coalesce(metrics.cohort_size, 0) as cohort_size,
  coalesce(metrics.availability_mask, 0) as availability_mask,
  metrics.population_band,
  map_category.category_label,
  map_category.incident_count,
  map_category.rate_per_1000,
  map_category.count_unit,
  map_category.rate_denominator,
  map_category.insee_pop,
  map_category.insee_pop_millesime,
  map_category.insee_log,
  map_category.insee_log_millesime,
  map_category.publication_status,
  map_percentile.category_percentile,
  ${PROPERTY_MARKET_SELECT_COLUMNS}
from cities c
join departments d on d.code = c.department_code
join regions r on r.code = c.region_code
left join active_snapshot on true
left join search_metrics_city_year_comparative metrics
  on metrics.snapshot_id = active_snapshot.snapshot_id
 and metrics.city_insee_code = c.insee_code
 and metrics.year = ${yearPlaceholder}
${mapCategoryJoin}
${propertyMarketJoin}
where ${[...visibleFilters, ...cityFilters].join("\n  and ")}
order by c.name, c.insee_code
`.trim()
  };
}

type Queryable = {
  query<T extends QueryResultRow>(
    text: string,
    values: Array<string | number | string[]>
  ): Promise<QueryResult<T>>;
};

type RawGroupRow = {
  snapshot_id: string | null;
  code: string;
  name: string;
  parent_code: string | null;
  parent_name: string | null;
  latitude: string;
  longitude: string;
  commune_count: number;
  west: string;
  south: string;
  east: string;
  north: string;
};

type RawNationalMapPoint = {
  snapshot_id: string | null;
  insee_code: string;
  name: string;
  department_code: string;
  department_name: string;
  region_code: string;
  region_name: string;
  latitude: string;
  longitude: string;
  population: number | null;
  population_year: number | null;
  category_label: string | null;
  incident_count: number | null;
  rate_per_1000: string | null;
  count_unit: string | null;
  rate_denominator: "population" | "housing" | "unknown";
  insee_pop: string | null;
  insee_pop_millesime: number | null;
  insee_log: string | null;
  insee_log_millesime: number | null;
  publication_status: "published" | "masked" | "unknown" | null;
  category_percentile: string | null;
} & ComparativeIndexColumns & PublishedMetricsColumns & RawPropertyMarketColumns;

type RawMapEnvironmentalRiskRow = {
  target_insee_code: string;
  target_coordinates_available: boolean | null;
  neighbor_insee_code: string | null;
  distance_km: string | null;
  comparative_index: string | number | null;
};

export async function searchNationalMap(
  db: Queryable,
  params: NationalMapParams
): Promise<NationalMapResult> {
  const query = buildNationalMapQuery(params);
  const level = params.level;
  if (level !== "commune") {
    const result = await db.query<RawGroupRow>(query.text, query.values);
    return {
      level,
      snapshotId: result.rows[0]?.snapshot_id ?? null,
      groups: result.rows.map((row) => ({
        type: level,
        code: row.code,
        name: row.name,
        parentCode: row.parent_code,
        parentName: row.parent_name,
        latitude: Number(row.latitude),
        longitude: Number(row.longitude),
        communeCount: row.commune_count,
        bounds: {
          west: Number(row.west),
          south: Number(row.south),
          east: Number(row.east),
          north: Number(row.north)
        }
      })),
      points: []
    };
  }

  const result = await db.query<RawNationalMapPoint>(query.text, query.values);
  const points: NationalMapPoint[] = result.rows.map((row) => {
    const comparative = mapComparativeIndex(row, row.population);
    return {
      inseeCode: row.insee_code,
      name: row.name,
      departmentCode: row.department_code,
      departmentName: row.department_name,
      regionCode: row.region_code,
      regionName: row.region_name,
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
      population: row.population,
      populationYear: row.population_year,
      published: mapPublishedMetrics(row),
      comparativeIndex: comparative.value,
      comparativeIndexStatus: comparative.status,
      comparativeIndexCompleteness: comparative.completeness,
      categoryLabel: row.category_label,
      categoryIncidentCount: row.incident_count,
      categoryRatePer1000: row.rate_per_1000,
      categoryPercentile: row.category_percentile,
      categoryCountUnit: row.count_unit,
      categoryRateDenominator: row.rate_denominator,
      categoryPopulationDenominator: row.insee_pop === null ? null : Number(row.insee_pop),
      categoryPopulationDenominatorYear: row.insee_pop_millesime,
      categoryHousingDenominator: row.insee_log === null ? null : Number(row.insee_log),
      categoryHousingDenominatorYear: row.insee_log_millesime,
      categoryPublicationStatus: row.publication_status,
      environmentalRisk: null,
      propertyMarket: propertyMarketSelectionFromParams(params)
        ? mapPropertyMarketMetric(row, propertyMarketSelectionFromParams(params) as PropertyMarketSelection)
        : null
    };
  });
  const snapshotId = result.rows[0]?.snapshot_id ?? null;
  if (params.criterion === "environmentalRisk" && snapshotId && points.length > 0) {
    const radius = params.environmentalRadiusKm as EnvironmentalRadiusKm;
    const codes = [...new Set(points.map((point) => point.inseeCode))];
    const environmentalQuery = buildMapEnvironmentalRiskQuery(
      codes,
      params.year,
      snapshotId,
      radius
    );
    const environmentalResult = await db.query<RawMapEnvironmentalRiskRow>(
      environmentalQuery.text,
      environmentalQuery.values
    );
    const groupedRows = new Map<string, {
      coordinatesAvailable: boolean;
      neighbors: EnvironmentalNeighborRow[];
    }>();
    for (const row of environmentalResult.rows) {
      let group = groupedRows.get(row.target_insee_code);
      if (!group) {
        group = {
          coordinatesAvailable: row.target_coordinates_available === true,
          neighbors: []
        };
        groupedRows.set(row.target_insee_code, group);
      }
      if (row.neighbor_insee_code === null || row.distance_km === null) continue;
      group.neighbors.push({
        targetInseeCode: row.target_insee_code,
        neighborInseeCode: row.neighbor_insee_code,
        distanceKm: Number(row.distance_km),
        comparativeIndex: row.comparative_index === null ? null : Number(row.comparative_index)
      });
    }
    for (const point of points) {
      const group = groupedRows.get(point.inseeCode);
      point.environmentalRisk = summarizeEnvironmentalRisk(
        point.inseeCode,
        radius,
        group?.coordinatesAvailable ?? true,
        group?.neighbors ?? []
      );
    }
  }
  return {
    level: "commune",
    snapshotId,
    groups: [],
    points
  };
}

function propertyMarketSelectionFromParams(params: NationalMapParams): PropertyMarketSelection | null {
  if (params.criterion === "salePrice" && params.marketPropertyType) {
    return { kind: "sale", propertyType: params.marketPropertyType };
  }
  if (
    params.criterion === "rentPrice"
    && params.marketPropertyType
    && params.marketPropertyType !== "all"
  ) {
    return { kind: "rent", propertyType: params.marketPropertyType };
  }
  return null;
}
