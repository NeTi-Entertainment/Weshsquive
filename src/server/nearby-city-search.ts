import type { QueryResult, QueryResultRow } from "pg";
import { z } from "zod";

import type { NearbyMapPoint } from "@/client/nearby-map-ui";
import {
  getMultipleHighExposureAlert,
  type ExposureAlertComponentInput,
  type MultipleHighExposureAlert
} from "@/shared/exposure-alert";

import {
  mapComparativeIndex,
  mapPublishedMetrics,
  type ComparativeIndex,
  type ComparativeIndexColumns,
  type PublishedMetrics,
  type PublishedMetricsColumns
} from "@/server/comparative-index";
import {
  ENVIRONMENTAL_RADII_KM,
  buildMapEnvironmentalRiskQuery,
  summarizeEnvironmentalRisk,
  type EnvironmentalNeighborRow,
  type EnvironmentalRadiusKm,
  type EnvironmentalRiskSummary
} from "@/server/environmental-risk";

export type NearbyCitySearchParams = {
  originInseeCode: string;
  year: number;
  radiusKm: EnvironmentalRadiusKm;
  environmentalRadiusKm?: EnvironmentalRadiusKm;
  populationMin?: number;
  populationMax?: number;
  comparativeIndexMin?: number;
  comparativeIndexMax?: number;
  categoryCode?: string;
  categoryIncidentMin?: number;
  categoryIncidentMax?: number;
  categoryRateMin?: number;
  categoryRateMax?: number;
  mapCategoryCode?: string;
  limit: number;
  offset: number;
};

export type NearbyCitySearchRow = {
  inseeCode: string;
  name: string;
  departmentCode: string;
  departmentName: string;
  regionCode: string;
  regionName: string;
  latitude: number;
  longitude: number;
  distanceKm: string;
  population: number | null;
  populationYear: number | null;
  published: PublishedMetrics;
  comparativeIndex: ComparativeIndex;
  multipleHighExposureAlert: MultipleHighExposureAlert | null;
  selectedCategory: {
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
  } | null;
};

export type NearbyCitySearchResult = {
  totalCount: number;
  results: NearbyCitySearchRow[];
  mapPoints: NearbyMapPoint[];
};

export type SqlQuery = {
  text: string;
  values: Array<string | number>;
};

export class NearbyOriginNotFoundError extends Error {
  constructor() {
    super("Commune origine introuvable");
    this.name = "NearbyOriginNotFoundError";
  }
}

const nearbySearchSchema = z.object({
  originInseeCode: z.string().trim().toUpperCase().regex(/^[0-9A-Z]{5}$/),
  year: z.coerce.number().int().min(2000).max(2100),
  radiusKm: z.coerce
    .number()
    .refine((value): value is 25 | 50 | 100 | 200 => [25, 50, 100, 200].includes(value))
    .default(50),
  environmentalRadiusKm: z.coerce
    .number()
    .refine((value): value is EnvironmentalRadiusKm =>
      ENVIRONMENTAL_RADII_KM.includes(value as EnvironmentalRadiusKm)
    )
    .optional(),
  populationMin: z.coerce.number().int().min(0).optional(),
  populationMax: z.coerce.number().int().min(0).optional(),
  comparativeIndexMin: z.coerce.number().int().min(0).max(100).optional(),
  comparativeIndexMax: z.coerce.number().int().min(0).max(100).optional(),
  categoryCode: z.string().trim().min(1).max(80).optional(),
  categoryIncidentMin: z.coerce.number().int().min(0).optional(),
  categoryIncidentMax: z.coerce.number().int().min(0).optional(),
  categoryRateMin: z.coerce.number().min(0).optional(),
  categoryRateMax: z.coerce.number().min(0).optional(),
  mapCategoryCode: z.string().trim().min(1).max(80).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(100),
  offset: z.coerce.number().int().min(0).default(0)
}).strict();

export function parseNearbyCitySearchParams(
  originInseeCode: string,
  params: URLSearchParams
): NearbyCitySearchParams {
  return nearbySearchSchema.parse({
    originInseeCode,
    ...Object.fromEntries(params.entries())
  });
}

export function buildNearbyCitySearchQuery(params: NearbyCitySearchParams): SqlQuery {
  const values: Array<string | number> = [
    params.originInseeCode,
    params.year,
    params.radiusKm * 1000
  ];
  const filters: string[] = [];

  const pushValue = (value: string | number) => {
    values.push(value);
    return `$${values.length}`;
  };

  const categoryPlaceholder = params.categoryCode
    ? pushValue(params.categoryCode)
    : null;
  const mapCategoryPlaceholder = params.mapCategoryCode
    ? pushValue(params.mapCategoryCode)
    : null;

  if (params.populationMin !== undefined || params.populationMax !== undefined) {
    filters.push("nm.population is not null");
  }

  if (params.populationMin !== undefined) {
    filters.push(`nm.population >= ${pushValue(params.populationMin)}`);
  }

  if (params.populationMax !== undefined) {
    filters.push(`nm.population <= ${pushValue(params.populationMax)}`);
  }

  if (params.comparativeIndexMin !== undefined) {
    filters.push(`nm.comparative_index >= ${pushValue(params.comparativeIndexMin)}`);
  }

  if (params.comparativeIndexMax !== undefined) {
    filters.push(`nm.comparative_index <= ${pushValue(params.comparativeIndexMax)}`);
  }

  if (categoryPlaceholder) {
    filters.push("nm.selected_category_publication_status = 'published'");

    if (params.categoryIncidentMin !== undefined) {
      filters.push(
        `nm.selected_category_incident_count >= ${pushValue(params.categoryIncidentMin)}`
      );
    }

    if (params.categoryIncidentMax !== undefined) {
      filters.push(
        `nm.selected_category_incident_count <= ${pushValue(params.categoryIncidentMax)}`
      );
    }

    if (params.categoryRateMin !== undefined) {
      filters.push("nm.selected_category_count_unit is not null and nm.selected_category_rate_denominator in ('population', 'housing')");
      filters.push(`nm.selected_category_rate_per_1000 >= ${pushValue(params.categoryRateMin)}`);
    }

    if (params.categoryRateMax !== undefined) {
      if (params.categoryRateMin === undefined) {
        filters.push("nm.selected_category_count_unit is not null and nm.selected_category_rate_denominator in ('population', 'housing')");
      }
      filters.push(`nm.selected_category_rate_per_1000 <= ${pushValue(params.categoryRateMax)}`);
    }
  }

  values.push(params.limit, params.offset);
  const limitPlaceholder = `$${values.length - 1}`;
  const offsetPlaceholder = `$${values.length}`;
  const finalWhere = filters.length > 0 ? `where ${filters.join("\n  and ")}` : "";
  const selectedCategoryJoin = categoryPlaceholder
    ? `left join lateral (
    select
      category.category_label as selected_category_label,
      category.incident_count as selected_category_incident_count,
      category.rate_per_1000 as selected_category_rate_per_1000,
      category.publication_status as selected_category_publication_status,
      category.count_unit as selected_category_count_unit,
      category.rate_denominator as selected_category_rate_denominator,
      category.insee_pop as selected_category_population_denominator,
      category.insee_pop_millesime as selected_category_population_denominator_year,
      category.insee_log as selected_category_housing_denominator,
      category.insee_log_millesime as selected_category_housing_denominator_year
    from search_metrics_city_year_category category
    where category.snapshot_id = active_snapshot.snapshot_id
      and category.city_insee_code = c.insee_code
      and category.year = $2
      and category.category_code = ${categoryPlaceholder}
    limit 1
  ) selected_category on true`
    : `left join lateral (
    select null::text as selected_category_label,
      null::integer as selected_category_incident_count,
      null::numeric as selected_category_rate_per_1000,
      null::text as selected_category_publication_status,
      null::text as selected_category_count_unit,
      'unknown'::text as selected_category_rate_denominator,
      null::bigint as selected_category_population_denominator,
      null::smallint as selected_category_population_denominator_year,
      null::bigint as selected_category_housing_denominator,
      null::smallint as selected_category_housing_denominator_year
  ) selected_category on true`;
  const mapCategoryCtes = mapCategoryPlaceholder
    ? `,
map_category_rates as (
  select
    category.city_insee_code,
    metrics.population_band,
    category.count_unit,
    category.rate_denominator,
    category.rate_per_1000
  from active_snapshot
  join search_metrics_city_year_category category
    on category.snapshot_id = active_snapshot.snapshot_id
   and category.year = $2
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
),
map_category_percentiles as (
  select
    city_insee_code,
    percent_rank() over (
      partition by population_band, count_unit, rate_denominator
      order by rate_per_1000
    ) as map_category_percentile
  from map_category_rates
)`
    : "";
  const mapCategoryJoin = mapCategoryPlaceholder
    ? `left join search_metrics_city_year_category map_category
    on map_category.snapshot_id = active_snapshot.snapshot_id
   and map_category.city_insee_code = c.insee_code
   and map_category.year = $2
   and map_category.category_code = ${mapCategoryPlaceholder}
  left join map_category_percentiles map_percentile
    on map_percentile.city_insee_code = c.insee_code
  left join exposure_index_category_anchors map_anchor
    on map_anchor.category_code = map_category.category_code`
    : `left join lateral (
    select
      null::text as category_code,
      null::text as category_label,
      null::numeric as rate_per_1000,
      null::text as publication_status,
      null::text as count_unit,
      'unknown'::text as rate_denominator,
      null::smallint as insee_pop_millesime,
      null::smallint as insee_log_millesime,
      null::numeric as category_exposure_score
  ) map_category on true
  left join lateral (select null::text as category_code) map_anchor on true
  left join lateral (
    select null::numeric as map_category_percentile
  ) map_percentile on true`;

  return {
    values,
    text: `
with active_snapshot as (
  select snapshot_id
  from search_metrics_active
  where singleton = true
)${mapCategoryCtes},
origin_city as (
  select geom
  from cities
  where insee_code = $1
    and geom is not null
),
origin_status as (
  select exists (
    select 1 from cities where insee_code = $1
  ) as origin_exists
),
nearby_metrics as (
  select
    c.insee_code,
    c.name,
    c.department_code,
    d.name as department_name,
    c.region_code,
    r.name as region_name,
    c.latitude,
    c.longitude,
    round((st_distance(c.geom, origin_city.geom) / 1000)::numeric, 3) as distance_km,
    metrics.population as population,
    metrics.population_year as population_year,
    coalesce(metrics.published_category_count, 0) as published_category_count,
    coalesce(metrics.total_category_count, 0) as total_category_count,
    metrics.coverage_ratio,
    metrics.comparative_index,
    coalesce(metrics.comparative_index_status, 'unavailable') as comparative_index_status,
    metrics.availability_mask,
    coalesce(metrics.historical_availability_mask, 0) as historical_availability_mask,
    coalesce(metrics.estimated_availability_mask, 0) as estimated_availability_mask,
    metrics.oldest_exposure_source_year,
    metrics.basket_version,
    coalesce(metrics.published_basket_category_count, 0) as published_basket_category_count,
    coalesce(metrics.historical_published_basket_category_count, 0) as historical_published_basket_category_count,
    coalesce(metrics.estimated_basket_category_count, 0) as estimated_basket_category_count,
    coalesce(metrics.effective_basket_category_count, 0) as effective_basket_category_count,
    metrics.basket_index_coverage,
    coalesce(metrics.low_volume_cap_applied, false) as low_volume_cap_applied,
    coalesce(metrics.comparative_index_provenance, 'unavailable') as comparative_index_provenance,
    selected_category.selected_category_label,
    selected_category.selected_category_incident_count,
    selected_category.selected_category_rate_per_1000,
    selected_category.selected_category_publication_status,
    selected_category.selected_category_count_unit,
    selected_category.selected_category_rate_denominator,
    selected_category.selected_category_population_denominator,
    selected_category.selected_category_population_denominator_year,
    selected_category.selected_category_housing_denominator,
    selected_category.selected_category_housing_denominator_year,
    map_category.category_label as map_category_label,
    map_category.rate_per_1000 as map_category_rate_per_1000,
    map_category.publication_status as map_category_publication_status,
    map_category.count_unit as map_category_count_unit,
    map_category.rate_denominator as map_category_rate_denominator,
    map_category.insee_pop_millesime as map_category_population_denominator_year,
    map_category.insee_log_millesime as map_category_housing_denominator_year,
    map_percentile.map_category_percentile,
    map_category.category_exposure_score as map_category_exposure_score,
    case when map_anchor.category_code is not null then 'absolute-exposure'
         when map_category.category_code is not null then 'percentile'
         else null end as map_category_color_mode,
    exposure_alert_data.components as exposure_components
  from origin_city
  cross join active_snapshot
  join cities c
    on c.insee_code <> $1
   and c.geom is not null
   and st_dwithin(c.geom, origin_city.geom, $3)
  join departments d on d.code = c.department_code
  join regions r on r.code = c.region_code
  left join search_metrics_city_year_comparative metrics
    on metrics.snapshot_id = active_snapshot.snapshot_id
   and metrics.city_insee_code = c.insee_code
   and metrics.year = $2
  ${selectedCategoryJoin}
  ${mapCategoryJoin}
  left join lateral (
    select coalesce(jsonb_agg(jsonb_build_object(
      'code', category.category_code,
      'label', category.category_label,
      'exposureScore', category.category_exposure_score,
      'exposureSourceYear', category.category_exposure_source_year,
      'exposureProvenance', category.category_exposure_source
    ) order by category.category_label), '[]'::jsonb) as components
    from search_metrics_city_year_category category
    join exposure_index_category_anchors basket
      on basket.category_code = category.category_code
    where category.snapshot_id = active_snapshot.snapshot_id
      and category.city_insee_code = c.insee_code
      and category.year = $2
      and category.category_exposure_score is not null
  ) exposure_alert_data on true
),
filtered_nearby as (
  select nm.*
  from nearby_metrics nm
  ${finalWhere}
),
filtered_count as (
  select count(*)::integer as total_count
  from filtered_nearby
),
map_points as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'inseeCode', insee_code,
    'name', name,
    'latitude', latitude,
    'longitude', longitude,
    'distanceKm', distance_km,
    'population', population,
    'populationYear', population_year,
    'comparative_index', comparative_index,
    'comparative_index_status', comparative_index_status,
    'basket_version', basket_version,
    'published_basket_category_count', published_basket_category_count,
    'historical_published_basket_category_count', historical_published_basket_category_count,
    'estimated_basket_category_count', estimated_basket_category_count,
    'effective_basket_category_count', effective_basket_category_count,
    'basket_index_coverage', basket_index_coverage,
    'low_volume_cap_applied', low_volume_cap_applied,
    'availability_mask', availability_mask,
    'historical_availability_mask', historical_availability_mask,
    'estimated_availability_mask', estimated_availability_mask,
    'oldest_exposure_source_year', oldest_exposure_source_year,
    'comparative_index_provenance', comparative_index_provenance,
    'categoryLabel', map_category_label,
    'categoryRatePer1000', map_category_rate_per_1000,
    'categoryPercentile', map_category_percentile,
    'categoryExposureScore', map_category_exposure_score,
    'categoryColorMode', map_category_color_mode,
    'categoryCountUnit', map_category_count_unit,
    'categoryRateDenominator', map_category_rate_denominator,
    'categoryPopulationDenominatorYear', map_category_population_denominator_year,
    'categoryHousingDenominatorYear', map_category_housing_denominator_year,
    'categoryPublicationStatus', map_category_publication_status,
    'exposureComponents', exposure_components
  ) order by distance_km, name, insee_code), '[]'::jsonb) as points
  from filtered_nearby
),
paged_nearby as (
  select *
  from filtered_nearby
  order by distance_km, name, insee_code
  limit ${limitPlaceholder}
  offset ${offsetPlaceholder}
)
select
  origin_status.origin_exists,
  (select snapshot_id from active_snapshot limit 1) as snapshot_id,
  paged_nearby.*,
  filtered_count.total_count,
  case when row_number() over (
    order by paged_nearby.distance_km nulls last, paged_nearby.name nulls last
  ) = 1 then map_points.points else null end as map_points
from origin_status
cross join filtered_count
cross join map_points
left join paged_nearby on true
order by paged_nearby.distance_km nulls last, paged_nearby.name nulls last
`.trim()
  };
}

type Queryable = {
  query<T extends QueryResultRow>(
    text: string,
    values: Array<string | number | string[]>
  ): Promise<QueryResult<T>>;
};

type RawNearbyMapPoint = Omit<NearbyMapPoint, "comparativeIndex" | "environmentalRisk" | "multipleHighExposureAlert"> &
  ComparativeIndexColumns & { exposureComponents: ExposureAlertComponentInput[] };

type RawNearbyCityRow = {
  origin_exists: boolean;
  snapshot_id: string | null;
  insee_code: string | null;
  name: string;
  department_code: string;
  department_name: string;
  region_code: string;
  region_name: string;
  latitude: string;
  longitude: string;
  distance_km: string;
  population: number | null;
  population_year: number | null;
  selected_category_label: string | null;
  selected_category_incident_count: number | null;
  selected_category_rate_per_1000: string | null;
  selected_category_publication_status: "published" | "masked" | "unknown" | null;
  selected_category_count_unit: string | null;
  selected_category_rate_denominator: "population" | "housing" | "unknown";
  selected_category_population_denominator: string | null;
  selected_category_population_denominator_year: number | null;
  selected_category_housing_denominator: string | null;
  selected_category_housing_denominator_year: number | null;
  total_count: number;
  map_points: RawNearbyMapPoint[] | null;
  exposure_components: ExposureAlertComponentInput[] | null;
} & ComparativeIndexColumns & PublishedMetricsColumns;

type RawMapEnvironmentalRiskRow = {
  target_insee_code: string;
  target_coordinates_available: boolean | null;
  neighbor_insee_code: string | null;
  distance_km: string | null;
  comparative_index: string | number | null;
  oldest_exposure_source_year: number | null;
  comparative_index_provenance: ComparativeIndex["provenance"];
};

export async function searchNearbyCities(
  db: Queryable,
  params: NearbyCitySearchParams
): Promise<NearbyCitySearchResult> {
  const query = buildNearbyCitySearchQuery(params);
  const result = await db.query<RawNearbyCityRow>(query.text, query.values);
  if (result.rows[0] && !result.rows[0].origin_exists) {
    throw new NearbyOriginNotFoundError();
  }

  const rows = result.rows.filter((row) => row.insee_code !== null);
  const mapPoints = (
    result.rows.find((row) => row.map_points !== null)?.map_points ?? []
  ).map(mapNearbyMapPoint);
  const environmentalRiskByCode = new Map<string, EnvironmentalRiskSummary>();

  if (params.environmentalRadiusKm !== undefined && mapPoints.length > 0) {
    const snapshotId = result.rows[0]?.snapshot_id;
    if (snapshotId) {
      const inseeCodes = [...new Set(mapPoints.map((point) => point.inseeCode))];
      const environmentalQuery = buildMapEnvironmentalRiskQuery(
        inseeCodes,
        params.year,
        snapshotId,
        params.environmentalRadiusKm
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
          comparativeIndex:
            row.comparative_index === null ? null : Number(row.comparative_index),
          comparativeIndexProvenance: row.comparative_index_provenance,
          oldestSourceYear: row.oldest_exposure_source_year
        });
      }

      for (const [targetCode, group] of groupedRows) {
        environmentalRiskByCode.set(
          targetCode,
          summarizeEnvironmentalRisk(
            targetCode,
            params.environmentalRadiusKm,
            group.coordinatesAvailable,
            group.neighbors
          )
        );
      }
    }
  }

  const enrichedMapPoints = mapPoints.map((point) => ({
    ...point,
    environmentalRisk: environmentalRiskByCode.get(point.inseeCode) ?? null
  }));

  return {
    totalCount: result.rows.length === 0 ? 0 : result.rows[0].total_count,
    mapPoints: enrichedMapPoints,
    results: rows.map((row) => {
      const comparativeIndex = mapComparativeIndex(row);
      return {
        inseeCode: row.insee_code as string,
        name: row.name,
        departmentCode: row.department_code,
        departmentName: row.department_name,
        regionCode: row.region_code,
        regionName: row.region_name,
        latitude: Number(row.latitude),
        longitude: Number(row.longitude),
        distanceKm: row.distance_km,
        population: row.population,
        populationYear: row.population_year,
        published: mapPublishedMetrics(row),
        comparativeIndex,
        multipleHighExposureAlert: getMultipleHighExposureAlert(
          comparativeIndex.value,
          row.exposure_components ?? []
        ),
        selectedCategory:
          params.categoryCode && row.selected_category_label && row.selected_category_publication_status
            ? {
                code: params.categoryCode,
                label: row.selected_category_label,
                incidentCount: row.selected_category_incident_count,
                ratePer1000: row.selected_category_rate_per_1000,
                countUnit: row.selected_category_count_unit,
                rateDenominator: row.selected_category_rate_denominator,
                populationDenominator:
                  row.selected_category_population_denominator === null
                    ? null
                    : Number(row.selected_category_population_denominator),
                populationDenominatorYear: row.selected_category_population_denominator_year,
                housingDenominator:
                  row.selected_category_housing_denominator === null
                    ? null
                    : Number(row.selected_category_housing_denominator),
                housingDenominatorYear: row.selected_category_housing_denominator_year,
                publicationStatus: row.selected_category_publication_status
              }
            : null
      };
    })
  };
}

function mapNearbyMapPoint(row: RawNearbyMapPoint): NearbyMapPoint {
  const comparativeIndex = mapComparativeIndex(row);
  return {
    inseeCode: row.inseeCode,
    name: row.name,
    latitude: Number(row.latitude),
    longitude: Number(row.longitude),
    distanceKm: row.distanceKm,
    population: row.population,
    populationYear: row.populationYear,
    comparativeIndex,
    multipleHighExposureAlert: getMultipleHighExposureAlert(
      comparativeIndex.value,
      row.exposureComponents ?? []
    ),
    categoryLabel: row.categoryLabel,
    categoryRatePer1000: row.categoryRatePer1000,
    categoryPercentile: row.categoryPercentile,
    categoryExposureScore: row.categoryExposureScore,
    categoryColorMode: row.categoryColorMode,
    categoryCountUnit: row.categoryCountUnit,
    categoryRateDenominator: row.categoryRateDenominator,
    categoryPopulationDenominatorYear: row.categoryPopulationDenominatorYear,
    categoryHousingDenominatorYear: row.categoryHousingDenominatorYear,
    categoryPublicationStatus: row.categoryPublicationStatus
  };
}
