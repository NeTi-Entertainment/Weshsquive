import { describe, expect, it, vi } from "vitest";

import {
  buildNearbyCitySearchQuery,
  parseNearbyCitySearchParams,
  searchNearbyCities
} from "../src/server/nearby-city-search";

const params = parseNearbyCitySearchParams("95594", new URLSearchParams({
  year: "2025",
  radiusKm: "25",
  limit: "10",
  offset: "1000"
}));

describe("nearby city search", () => {
  it("rejects environmental radii outside the supported set", () => {
    expect(() => parseNearbyCitySearchParams("95594", new URLSearchParams({
      year: "2025",
      environmentalRadiusKm: "30"
    }))).toThrow();
  });

  it("excludes unknown populations when a population bound is active", () => {
    const query = buildNearbyCitySearchQuery({
      ...params,
      populationMin: 0,
      populationMax: 1000
    });

    expect(query.text).toContain("nm.population is not null");
    expect(query.text).toContain("nm.population >= $4");
    expect(query.text).toContain("nm.population <= $5");
    expect(query.text).not.toContain("coalesce(nm.population, 0)");
  });

  it("keeps the filtered total when the requested page has no rows", async () => {
    const query = buildNearbyCitySearchQuery(params);
    const mapPoint = {
      inseeCode: "95584",
      name: "Seugy",
      latitude: 49.121,
      longitude: 2.391,
      distanceKm: 12.5,
      population: 1044,
      populationYear: 2023,
      comparativeIndex: 82,
      comparativeIndexStatus: "comparable",
      comparativeIndexCompleteness: "high",
      categoryLabel: null,
      categoryRatePer1000: null,
      categoryPercentile: null,
      categoryCountUnit: null,
      categoryRateDenominator: "unknown",
      categoryPopulationDenominatorYear: null,
      categoryHousingDenominatorYear: null,
      categoryPublicationStatus: null
    };
    const db = {
      query: vi.fn().mockResolvedValue({
        rows: [{
          origin_exists: true,
          insee_code: null,
          total_count: 237,
          map_points: [mapPoint]
        }],
        rowCount: 1
      })
    };

    expect(query.text).toContain("filtered_count as (");
    expect(query.text).toContain("map_points as (");
    expect(query.text).toContain("jsonb_agg(");
    expect(query.text).toContain("left join paged_nearby on true");
    await expect(searchNearbyCities(db as never, params)).resolves.toEqual({
      totalCount: 237,
      results: [],
      mapPoints: [{ ...mapPoint, environmentalRisk: null }]
    });
    expect(db.query).toHaveBeenCalledTimes(1);
  });

  it("batches environmental summaries for unique map points using the active snapshot", async () => {
    const environmentalParams = parseNearbyCitySearchParams("95594", new URLSearchParams({
      year: "2025",
      radiusKm: "25",
      environmentalRadiusKm: "25",
      populationMin: "1000",
      comparativeIndexMax: "80",
      categoryCode: "ssmsi-cambriolages",
      categoryIncidentMin: "1",
      mapCategoryCode: "ssmsi-cambriolages",
      limit: "10",
      offset: "1000"
    }));
    const mapPoints = [
      makeMapPoint("95584"),
      makeMapPoint("95584"),
      makeMapPoint("95313")
    ];
    const db = {
      query: vi.fn()
        .mockResolvedValueOnce({
          rows: [{
            origin_exists: true,
            snapshot_id: "snapshot-17",
            insee_code: null,
            total_count: 0,
            map_points: mapPoints
          }],
          rowCount: 1
        })
        .mockResolvedValueOnce({
          rows: [
            environmentalRow("95584", "01001", "0", "20"),
            environmentalRow("95584", "01002", "12.5", "80"),
            environmentalRow("95584", "01003", "10", "40"),
            environmentalRow("95584", "01004", "2", null),
            environmentalRow("95313", "01005", "0", "30"),
            environmentalRow("95313", "01006", "0", "50"),
            environmentalRow("95313", "01007", "0", "70")
          ],
          rowCount: 7
        })
    };

    const result = await searchNearbyCities(db as never, environmentalParams);

    expect(db.query).toHaveBeenCalledTimes(2);
    const [batchSql, batchValues] = db.query.mock.calls[1];
    expect(batchValues).toEqual([["95584", "95313"], 2025, "snapshot-17", 25000]);
    expect(batchSql).toContain("unnest($1::varchar[])");
    expect(batchSql).toContain("metrics.year = $2");
    expect(batchSql).toContain("metrics.snapshot_id = $3");
    expect(batchSql).toContain("st_dwithin");
    expect(batchSql).not.toContain("population_min");
    expect(batchSql).not.toContain("limit 10");
    expect(result.results).toEqual([]);
    expect(result.mapPoints[0].environmentalRisk).toMatchObject({
      radiusKm: 25,
      value: 40,
      status: "comparable",
      scoredNeighborCount: 3,
      totalNeighborCount: 4
    });
    expect(result.mapPoints[0].environmentalRisk?.weightedCoverageRatio).toBeCloseTo(
      2.1 / 3.02
    );
    expect(result.mapPoints[1].environmentalRisk).toEqual(
      result.mapPoints[0].environmentalRisk
    );
    expect(result.mapPoints[2].environmentalRisk).toMatchObject({
      value: 50,
      status: "comparable",
      scoredNeighborCount: 3,
      totalNeighborCount: 3,
      weightedCoverageRatio: 1
    });
  });

  it("does not run the environmental batch when there are no map points", async () => {
    const environmentalParams = parseNearbyCitySearchParams("95594", new URLSearchParams({
      year: "2025",
      environmentalRadiusKm: "50"
    }));
    const db = {
      query: vi.fn().mockResolvedValue({
        rows: [{
          origin_exists: true,
          snapshot_id: "snapshot-17",
          insee_code: null,
          total_count: 0,
          map_points: []
        }],
        rowCount: 1
      })
    };

    await expect(searchNearbyCities(db as never, environmentalParams)).resolves.toMatchObject({
      mapPoints: []
    });
    expect(db.query).toHaveBeenCalledTimes(1);
  });

  it("does not guess a snapshot when environmental mode has no active snapshot", async () => {
    const environmentalParams = parseNearbyCitySearchParams("95594", new URLSearchParams({
      year: "2025",
      environmentalRadiusKm: "50"
    }));
    const db = {
      query: vi.fn().mockResolvedValue({
        rows: [{
          origin_exists: true,
          snapshot_id: null,
          insee_code: null,
          total_count: 0,
          map_points: [makeMapPoint("95584")]
        }],
        rowCount: 1
      })
    };

    const result = await searchNearbyCities(db as never, environmentalParams);

    expect(db.query).toHaveBeenCalledTimes(1);
    expect(result.mapPoints[0].environmentalRisk).toBeNull();
  });

  it("ranks a map category only against published values with the same comparison base", () => {
    const query = buildNearbyCitySearchQuery({
      ...params,
      offset: 0,
      mapCategoryCode: "ssmsi-cambriolages"
    });

    expect(query.values).toEqual([
      "95594",
      2025,
      25000,
      "ssmsi-cambriolages",
      10,
      0
    ]);
    expect(query.text).toContain("map_category_rates as (");
    expect(query.text).toContain("category.publication_status = 'published'");
    expect(query.text).toContain(
      "partition by population_band, count_unit, rate_denominator"
    );
    expect(query.text).toContain("map_category_percentile");
  });

  it("checks origin existence independently from nearby results", () => {
    const query = buildNearbyCitySearchQuery({ ...params, categoryCode: "ssmsi-cambriolages" });

    expect(query.text).toContain("search_metrics_active");
    expect(query.text).toContain("search_metrics_city_year_comparative");
    expect(query.text).toContain("search_metrics_city_year_category");
    expect(query.text).not.toContain("population_history ph");
    expect(query.text).not.toContain("selected_population");
    expect(query.text).not.toContain("c.reference_population");
    expect(query.text).not.toContain("city_year_comparative_metrics");
    expect(query.text).not.toContain("city_year_category_metrics");
    expect(query.text).toContain("origin_status as (");
    expect(query.text).toContain("as origin_exists");
    expect(query.text).toContain("from origin_status\ncross join filtered_count");
  });

  it("rejects an unknown origin instead of returning an empty result", async () => {
    const db = {
      query: vi.fn().mockResolvedValue({
        rows: [{ origin_exists: false, insee_code: null, total_count: 0 }],
        rowCount: 1
      })
    };

    await expect(searchNearbyCities(db as never, params)).rejects.toThrow(
      "Commune origine introuvable"
    );
  });
});

function makeMapPoint(inseeCode: string) {
  return {
    inseeCode,
    name: "Seugy",
    latitude: 49.121,
    longitude: 2.391,
    distanceKm: 12.5,
    population: 1044,
    populationYear: 2023,
    comparativeIndex: 82,
    comparativeIndexStatus: "comparable",
    comparativeIndexCompleteness: "high",
    categoryLabel: null,
    categoryRatePer1000: null,
    categoryPercentile: null,
    categoryCountUnit: null,
    categoryRateDenominator: "unknown",
    categoryPopulationDenominatorYear: null,
    categoryHousingDenominatorYear: null,
    categoryPublicationStatus: null
  };
}

function environmentalRow(
  targetInseeCode: string,
  neighborInseeCode: string,
  distanceKm: string,
  comparativeIndex: string | null
) {
  return {
    target_insee_code: targetInseeCode,
    target_coordinates_available: true,
    neighbor_insee_code: neighborInseeCode,
    distance_km: distanceKm,
    comparative_index: comparativeIndex
  };
}
