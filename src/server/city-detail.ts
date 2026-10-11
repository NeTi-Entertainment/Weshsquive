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
import {
  ENVIRONMENTAL_RADII_KM,
  buildCityEnvironmentalRiskQuery,
  summarizeEnvironmentalRisk,
  type EnvironmentalNeighborRow,
  type EnvironmentalRadiusKm,
  type EnvironmentalRiskSummary
} from "@/server/environmental-risk";
import type { ExposureComponentSource } from "@/shared/exposure-index";
import { getMultipleHighExposureAlert, type MultipleHighExposureAlert } from "@/shared/exposure-alert";

type RateDenominator = "population" | "housing" | "unknown";
type PublicationStatus = "published" | "masked" | "unknown";
type CategoryMetrics = {
  code: string; label: string; incidentCount: number | null; ratePer1000: string | null;
  countUnit: string | null; rateDenominator: RateDenominator;
  populationDenominator: number | null; populationDenominatorYear: number | null;
  housingDenominator: number | null; housingDenominatorYear: number | null;
  publicationStatus: PublicationStatus;
  exposureSourceYear: number | null; exposureProvenance: ExposureComponentSource | null;
  exposureRatePer1000: number | null; exposureScore: number | null;
};
type HistoryObservation = Omit<
  CategoryMetrics,
  "code" | "label" | "exposureSourceYear" | "exposureProvenance" | "exposureRatePer1000" | "exposureScore"
> & { year: number };
type ComparisonScope = {
  scope: "commune" | "department" | "region" | "france";
  ratePer1000: string | null; publishedCityCount: number; totalCityCount: number;
  coverageRatio: string | null; denominatorYears: number[];
};

export type CityDetailParams = { inseeCode: string; year: number; categoryCode?: string };
export type CityDetail = {
  inseeCode: string; name: string; departmentCode: string; departmentName: string;
  regionCode: string; regionName: string; latitude: number | null; longitude: number | null;
  population: number | null; populationYear: number | null; year: number;
  published: PublishedMetrics; comparativeIndex: ComparativeIndex;
  multipleHighExposureAlert: MultipleHighExposureAlert | null;
  categories: CategoryMetrics[];
  comparisons: Array<{
    code: string; label: string; countUnit: string | null;
    rateDenominator: RateDenominator; scopes: ComparisonScope[];
  }>;
  historyByCategory: Array<{ code: string; label: string; observations: HistoryObservation[] }>;
  selectedHistoryCategoryCode: string | null;
  environmentalRisk: EnvironmentalRiskSummary[];
};
export type SqlQuery = { text: string; values: Array<string | number> };

const cityDetailSchema = z.object({
  inseeCode: z.string().trim().toUpperCase().regex(/^[0-9A-Z]{5}$/),
  year: z.coerce.number().int().min(2000).max(2100).default(2025),
  categoryCode: z.string().trim().min(1).max(80).optional()
});

export function parseCityDetailParams(inseeCode: string, params: URLSearchParams): CityDetailParams {
  return cityDetailSchema.parse({
    inseeCode, year: params.get("year") ?? undefined,
    categoryCode: params.get("categoryCode") ?? undefined
  });
}

export function buildCityDetailQuery(params: CityDetailParams): SqlQuery {
  return {
    values: [params.inseeCode, params.year],
    text: `
with active_snapshot as (
  select snapshot_id from search_metrics_active where singleton = true
), target_city as (
  select active_snapshot.snapshot_id as snapshot_id, c.insee_code, c.name, c.department_code, d.name as department_name,
    c.region_code, r.name as region_name, c.latitude, c.longitude,
    metrics.population as population,
    metrics.population_year as population_year
  from active_snapshot
  cross join cities c
  join departments d on d.code = c.department_code
  join regions r on r.code = c.region_code
  left join search_metrics_city_year_comparative metrics
    on metrics.snapshot_id = active_snapshot.snapshot_id
   and metrics.city_insee_code = c.insee_code and metrics.year = $2
  where c.insee_code = $1
), target_metrics as (
  select metrics.* from search_metrics_city_year_comparative metrics
  join active_snapshot using (snapshot_id)
  where metrics.city_insee_code = $1 and metrics.year = $2
)
select tc.*,
  coalesce(tm.published_category_count, 0) as published_category_count,
  coalesce(tm.total_category_count, 0) as total_category_count,
  tm.coverage_ratio, tm.comparative_index,
  coalesce(tm.comparative_index_status, 'unavailable') as comparative_index_status,
  tm.availability_mask,
  coalesce(tm.estimated_availability_mask, 0) as estimated_availability_mask,
  coalesce(tm.historical_availability_mask, 0) as historical_availability_mask,
  tm.basket_version,
  coalesce(tm.published_basket_category_count, 0) as published_basket_category_count,
  coalesce(tm.historical_published_basket_category_count, 0) as historical_published_basket_category_count,
  coalesce(tm.estimated_basket_category_count, 0) as estimated_basket_category_count,
  coalesce(tm.effective_basket_category_count, 0) as effective_basket_category_count,
  tm.oldest_exposure_source_year,
  tm.basket_index_coverage,
  coalesce(tm.low_volume_cap_applied, false) as low_volume_cap_applied,
  coalesce(tm.comparative_index_provenance, 'unavailable') as comparative_index_provenance,
  coalesce(category_data.categories, '[]'::jsonb) as categories
from target_city tc
left join target_metrics tm on true
left join lateral (
  select jsonb_agg(jsonb_build_object(
    'code', category.category_code, 'label', category.category_label,
    'incidentCount', category.incident_count, 'ratePer1000', category.rate_per_1000,
    'countUnit', category.count_unit, 'rateDenominator', category.rate_denominator,
    'populationDenominator', category.insee_pop,
    'populationDenominatorYear', category.insee_pop_millesime,
    'housingDenominator', category.insee_log,
    'housingDenominatorYear', category.insee_log_millesime,
    'publicationStatus', category.publication_status,
    'exposureSourceYear', category.category_exposure_source_year,
    'exposureProvenance', category.category_exposure_source,
    'exposureRatePer1000', category.category_exposure_rate_per_1000,
    'exposureScore', category.category_exposure_score
  ) order by category.category_label) as categories
  from search_metrics_city_year_category category
  where category.snapshot_id = tc.snapshot_id
    and category.city_insee_code = $1 and category.year = $2
) category_data on true
`.trim()
  };
}

export function buildCityHistoryQuery(inseeCode: string, snapshotId: string): SqlQuery {
  return {
    values: [inseeCode, snapshotId],
    text: `
select category_code, category_label, year, incident_count, rate_per_1000,
  count_unit, rate_denominator, insee_pop, insee_pop_millesime,
  insee_log, insee_log_millesime, publication_status
from search_metrics_city_year_category
where city_insee_code = $1 and snapshot_id = $2
order by category_label, year
`.trim()
  };
}

export function buildCityComparisonQuery(params: CityDetailParams, snapshotId: string): SqlQuery {
  return {
    values: [params.inseeCode, params.year, snapshotId],
    text: `
with target_city as (
  select insee_code, department_code, region_code from cities where insee_code = $1
), target_categories as (
  select category_code, category_label, count_unit, rate_denominator,
    rate_per_1000, publication_status
  from search_metrics_city_year_category
  where city_insee_code = $1 and year = $2 and snapshot_id = $3
), scope_cities as (
  select 'commune'::text as scope, insee_code as city_insee_code from target_city
  union all
  select 'department', c.insee_code from target_city tc
    join cities c on c.department_code = tc.department_code
  union all
  select 'region', c.insee_code from target_city tc
    join cities c on c.region_code = tc.region_code
  union all
  select 'france', c.insee_code from cities c
)
select target.category_code, target.category_label, target.count_unit,
  target.rate_denominator, scope.scope,
  case when scope.scope = 'commune' then max(target.rate_per_1000) filter (where
    target.publication_status = 'published'
  ) else round(
      sum(observation.incident_count) filter (where
        observation.publication_status = 'published' and observation.incident_count is not null
        and case target.rate_denominator
          when 'population' then observation.insee_pop > 0
          when 'housing' then observation.insee_log > 0 else false end
      )::numeric * 1000 / nullif(
        sum(case target.rate_denominator
          when 'population' then observation.insee_pop
          when 'housing' then observation.insee_log else null end) filter (where
            observation.publication_status = 'published'
            and observation.incident_count is not null
            and case target.rate_denominator
              when 'population' then observation.insee_pop > 0
              when 'housing' then observation.insee_log > 0 else false end
          ), 0), 4
    ) end as rate_per_1000,
  count(scope.city_insee_code)::integer as total_city_count,
  case when scope.scope = 'commune' then
    count(scope.city_insee_code) filter (where
      target.publication_status = 'published' and target.rate_per_1000 is not null
    )
  else count(observation.city_insee_code) filter (where
      observation.publication_status = 'published' and observation.incident_count is not null
      and case target.rate_denominator
        when 'population' then observation.insee_pop > 0
        when 'housing' then observation.insee_log > 0 else false end
    ) end::integer as published_city_count,
  case when count(scope.city_insee_code) > 0 then
    (case when scope.scope = 'commune' then
      count(scope.city_insee_code) filter (where
        target.publication_status = 'published' and target.rate_per_1000 is not null
      )
    else count(observation.city_insee_code) filter (where
        observation.publication_status = 'published' and observation.incident_count is not null
        and case target.rate_denominator
          when 'population' then observation.insee_pop > 0
          when 'housing' then observation.insee_log > 0 else false end
      ) end)::numeric / count(scope.city_insee_code)
  else null end as coverage_ratio,
  coalesce(array_agg(distinct case target.rate_denominator
    when 'population' then observation.insee_pop_millesime
    when 'housing' then observation.insee_log_millesime else null end
    order by case target.rate_denominator
      when 'population' then observation.insee_pop_millesime
      when 'housing' then observation.insee_log_millesime else null end
  ) filter (where observation.publication_status = 'published'
    and observation.incident_count is not null
    and case target.rate_denominator
      when 'population' then observation.insee_pop > 0
      when 'housing' then observation.insee_log > 0 else false end
    and case target.rate_denominator
      when 'population' then observation.insee_pop_millesime is not null
      when 'housing' then observation.insee_log_millesime is not null else false end
  ), '{}'::smallint[]) as denominator_years
from target_categories target
cross join scope_cities scope
left join search_metrics_city_year_category observation
  on observation.city_insee_code = scope.city_insee_code
  and observation.year = $2
  and observation.snapshot_id = $3
  and observation.category_code = target.category_code
  and target.count_unit is not null
  and target.rate_denominator <> 'unknown'
  and observation.count_unit is not distinct from target.count_unit
  and observation.rate_denominator = target.rate_denominator
group by target.category_code, target.category_label, target.count_unit,
  target.rate_denominator, scope.scope
order by target.category_label, scope.scope
`.trim()
  };
}

type Queryable = {
  query<T extends QueryResultRow>(text: string, values: Array<string | number>): Promise<QueryResult<T>>;
};
type RawCityDetailRow = {
  snapshot_id: string; insee_code: string; name: string; department_code: string; department_name: string;
  region_code: string; region_name: string; latitude: string | null; longitude: string | null;
  population: number | null; population_year: number | null;
  categories: CategoryMetrics[];
} & ComparativeIndexColumns & PublishedMetricsColumns;
type RawHistoryRow = {
  category_code: string; category_label: string; year: number; incident_count: number | null;
  rate_per_1000: string | null; count_unit: string | null; rate_denominator: RateDenominator;
  insee_pop: string | null; insee_pop_millesime: number | null;
  insee_log: string | null; insee_log_millesime: number | null;
  publication_status: PublicationStatus;
};
type RawComparisonRow = {
  category_code: string; category_label: string; count_unit: string | null;
  rate_denominator: RateDenominator; scope: ComparisonScope["scope"];
  rate_per_1000: string | null; total_city_count: number; published_city_count: number;
  coverage_ratio: string | null; denominator_years: number[];
};
type RawEnvironmentalRiskRow = {
  radius_km: EnvironmentalRadiusKm;
  target_coordinates_available: boolean;
  neighbor_insee_code: string | null;
  distance_km: number | null;
  comparative_index: string | number | null;
  oldest_exposure_source_year: number | null;
  comparative_index_provenance: ComparativeIndex["provenance"];
};

export async function getCityDetail(db: Queryable, params: CityDetailParams): Promise<CityDetail | null> {
  const detailQuery = buildCityDetailQuery(params);
  const detailResult = await db.query<RawCityDetailRow>(detailQuery.text, detailQuery.values);
  const row = detailResult.rows[0];
  if (!row) return null;

  const historyQuery = buildCityHistoryQuery(params.inseeCode, row.snapshot_id);
  const comparisonsQuery = buildCityComparisonQuery(params, row.snapshot_id);
  const environmentalQuery = buildCityEnvironmentalRiskQuery(
    params.inseeCode, params.year, row.snapshot_id
  );
  const [historyResult, comparisonsResult, environmentalResult] = await Promise.all([
    db.query<RawHistoryRow>(historyQuery.text, historyQuery.values),
    db.query<RawComparisonRow>(comparisonsQuery.text, comparisonsQuery.values),
    db.query<RawEnvironmentalRiskRow>(environmentalQuery.text, environmentalQuery.values)
  ]);

  const historyMap = new Map<string, CityDetail["historyByCategory"][number]>();
  for (const item of historyResult.rows) {
    let category = historyMap.get(item.category_code);
    if (!category) {
      category = { code: item.category_code, label: item.category_label, observations: [] };
      historyMap.set(item.category_code, category);
    }
    category.observations.push({
      year: item.year, incidentCount: item.incident_count, ratePer1000: item.rate_per_1000,
      countUnit: item.count_unit, rateDenominator: item.rate_denominator,
      populationDenominator: nullableNumber(item.insee_pop),
      populationDenominatorYear: item.insee_pop_millesime,
      housingDenominator: nullableNumber(item.insee_log),
      housingDenominatorYear: item.insee_log_millesime,
      publicationStatus: item.publication_status
    });
  }

  const comparisonsMap = new Map<string, CityDetail["comparisons"][number]>();
  for (const item of comparisonsResult.rows) {
    let category = comparisonsMap.get(item.category_code);
    if (!category) {
      category = {
        code: item.category_code, label: item.category_label,
        countUnit: item.count_unit, rateDenominator: item.rate_denominator, scopes: []
      };
      comparisonsMap.set(item.category_code, category);
    }
    category.scopes.push({
      scope: item.scope, ratePer1000: item.rate_per_1000,
      publishedCityCount: item.published_city_count, totalCityCount: item.total_city_count,
      coverageRatio: item.coverage_ratio, denominatorYears: item.denominator_years.map(Number)
    });
  }

  const historyByCategory = Array.from(historyMap.values());
  const selectedHistoryCategoryCode =
    (params.categoryCode && historyMap.has(params.categoryCode) ? params.categoryCode : null) ??
    historyByCategory.find((category) =>
      category.observations.some((observation) => observation.publicationStatus === "published")
    )?.code ?? historyByCategory[0]?.code ?? null;

  const environmentalNeighbors = new Map<EnvironmentalRadiusKm, EnvironmentalNeighborRow[]>(
    ENVIRONMENTAL_RADII_KM.map((radiusKm) => [radiusKm, []])
  );
  for (const item of environmentalResult.rows) {
    if (item.neighbor_insee_code === null || item.distance_km === null) continue;
    environmentalNeighbors.get(item.radius_km)?.push({
      targetInseeCode: params.inseeCode,
      neighborInseeCode: item.neighbor_insee_code,
      distanceKm: Number(item.distance_km),
      comparativeIndex: item.comparative_index === null ? null : Number(item.comparative_index),
      comparativeIndexProvenance: item.comparative_index_provenance,
      oldestSourceYear: item.oldest_exposure_source_year
    });
  }
  const coordinatesAvailable = environmentalResult.rows[0]?.target_coordinates_available ??
    (row.latitude !== null && row.longitude !== null);
  const environmentalRisk = ENVIRONMENTAL_RADII_KM.map((radiusKm) =>
    summarizeEnvironmentalRisk(
      params.inseeCode,
      radiusKm,
      coordinatesAvailable,
      environmentalNeighbors.get(radiusKm) ?? []
    )
  );

  return {
    inseeCode: row.insee_code, name: row.name,
    departmentCode: row.department_code, departmentName: row.department_name,
    regionCode: row.region_code, regionName: row.region_name,
    latitude: row.latitude === null ? null : Number(row.latitude),
    longitude: row.longitude === null ? null : Number(row.longitude),
    population: row.population, populationYear: row.population_year, year: params.year,
    published: mapPublishedMetrics(row), comparativeIndex: mapComparativeIndex(row),
    multipleHighExposureAlert: getMultipleHighExposureAlert(row.categories),
    categories: row.categories, comparisons: Array.from(comparisonsMap.values()),
    historyByCategory, selectedHistoryCategoryCode, environmentalRisk
  };
}

function nullableNumber(value: string | null): number | null {
  return value === null ? null : Number(value);
}
