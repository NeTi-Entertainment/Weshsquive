export const ENVIRONMENTAL_RADII_KM = [25, 50, 100, 200] as const;

export type EnvironmentalRadiusKm = (typeof ENVIRONMENTAL_RADII_KM)[number];
export type EnvironmentalRiskStatus =
  | "comparable"
  | "insufficient-coverage"
  | "no-neighbors"
  | "coordinates-unavailable";

export type EnvironmentalRiskSummary = {
  radiusKm: EnvironmentalRadiusKm;
  value: number | null;
  status: EnvironmentalRiskStatus;
  scoredNeighborCount: number;
  totalNeighborCount: number;
  weightedCoverageRatio: number | null;
};

export type EnvironmentalNeighborRow = {
  targetInseeCode: string;
  neighborInseeCode: string;
  distanceKm: number;
  comparativeIndex: number | null;
};

type CityEnvironmentalRiskQuery = {
  text: string;
  values: [string, number, string];
};

type MapEnvironmentalRiskQuery = {
  text: string;
  values: [string[], number, string, number];
};

export function buildCityEnvironmentalRiskQuery(
  inseeCode: string,
  year: number,
  snapshotId: string
): CityEnvironmentalRiskQuery {
  return {
    values: [inseeCode, year, snapshotId],
    text: `
with target as (
  select insee_code, geom, (geom is not null) as coordinates_available
  from cities
  where insee_code = $1
), environmental_radii(radius_km) as (
  values (25::integer), (50::integer), (100::integer), (200::integer)
)
select
  environmental_radii.radius_km,
  target.coordinates_available as target_coordinates_available,
  target.insee_code as target_insee_code,
  neighbor.insee_code as neighbor_insee_code,
  neighbor.distance_km,
  metrics.comparative_index
from target
cross join environmental_radii
left join lateral (
  select
    c.insee_code,
    c.geom,
    st_distance(c.geom, target.geom) / 1000.0 as distance_km
  from cities c
  where target.geom is not null
    and c.geom is not null
    and c.insee_code <> target.insee_code
    and st_dwithin(c.geom, target.geom, environmental_radii.radius_km * 1000)
    and st_distance(c.geom, target.geom) < environmental_radii.radius_km * 1000
) neighbor on true
left join search_metrics_city_year_comparative metrics
  on metrics.city_insee_code = neighbor.insee_code
 and metrics.year = $2
 and metrics.snapshot_id = $3
order by environmental_radii.radius_km, neighbor.insee_code
`.trim()
  };
}

export function buildMapEnvironmentalRiskQuery(
  inseeCodes: string[],
  year: number,
  snapshotId: string,
  radiusKm: EnvironmentalRadiusKm
): MapEnvironmentalRiskQuery {
  return {
    values: [inseeCodes, year, snapshotId, radiusKm * 1000],
    text: `
with requested_targets as (
  select unnest($1::varchar[]) as requested_insee_code
), targets as (
  select
    requested_targets.requested_insee_code,
    cities.insee_code,
    cities.geom,
    (cities.geom is not null) as coordinates_available
  from requested_targets
  left join cities on cities.insee_code = requested_targets.requested_insee_code
)
select
  targets.requested_insee_code as target_insee_code,
  targets.coordinates_available as target_coordinates_available,
  neighbor.insee_code as neighbor_insee_code,
  neighbor.distance_km,
  metrics.comparative_index
from targets
left join lateral (
  select
    c.insee_code,
    c.geom,
    st_distance(c.geom, targets.geom) / 1000.0 as distance_km
  from cities c
  where targets.geom is not null
    and c.geom is not null
    and c.insee_code <> targets.insee_code
    and st_dwithin(c.geom, targets.geom, $4)
    and st_distance(c.geom, targets.geom) < $4
) neighbor on true
left join search_metrics_city_year_comparative metrics
  on metrics.city_insee_code = neighbor.insee_code
 and metrics.year = $2
 and metrics.snapshot_id = $3
order by targets.requested_insee_code, neighbor.insee_code
`.trim()
  };
}

export function summarizeEnvironmentalRisk(
  targetCode: string,
  radiusKm: EnvironmentalRadiusKm,
  coordinatesAvailable: boolean,
  neighborRows: EnvironmentalNeighborRow[]
): EnvironmentalRiskSummary {
  if (!coordinatesAvailable) {
    return emptySummary(radiusKm, "coordinates-unavailable");
  }

  const neighbors = neighborRows.filter((neighbor) =>
    neighbor.neighborInseeCode !== targetCode &&
    Number.isFinite(neighbor.distanceKm) &&
    neighbor.distanceKm >= 0 &&
    neighbor.distanceKm < radiusKm
  );

  if (neighbors.length === 0) {
    return emptySummary(radiusKm, "no-neighbors");
  }

  let totalWeight = 0;
  let scoredWeight = 0;
  let weightedIndex = 0;
  let scoredNeighborCount = 0;

  for (const neighbor of neighbors) {
    const weight = 1 - neighbor.distanceKm / radiusKm;
    totalWeight += weight;

    if (neighbor.comparativeIndex === null || !Number.isFinite(neighbor.comparativeIndex)) {
      continue;
    }

    scoredNeighborCount += 1;
    scoredWeight += weight;
    weightedIndex += neighbor.comparativeIndex * weight;
  }

  const weightedCoverageRatio = scoredWeight / totalWeight;
  const comparable = scoredNeighborCount >= 3 && weightedCoverageRatio >= 0.5;

  return {
    radiusKm,
    value: comparable ? Math.round((weightedIndex / scoredWeight) * 10) / 10 : null,
    status: comparable ? "comparable" : "insufficient-coverage",
    scoredNeighborCount,
    totalNeighborCount: neighbors.length,
    weightedCoverageRatio
  };
}

function emptySummary(
  radiusKm: EnvironmentalRadiusKm,
  status: "no-neighbors" | "coordinates-unavailable"
): EnvironmentalRiskSummary {
  return {
    radiusKm,
    value: null,
    status,
    scoredNeighborCount: 0,
    totalNeighborCount: 0,
    weightedCoverageRatio: null
  };
}
