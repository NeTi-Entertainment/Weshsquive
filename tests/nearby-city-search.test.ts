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

const partiallyEstimatedBasketAvailability = [
  { code: "ssmsi-78384436563146dc6167ea53b7b5e0cd", label: "Cambriolages de logement", available: true, estimated: false, historical: false },
  { code: "ssmsi-74a195792dd119f60822e61df3587522", label: "Vols de véhicule", available: true, estimated: false, historical: false },
  { code: "ssmsi-d3e9d2e40d72b8850d5283eb73bdc928", label: "Vols dans les véhicules", available: true, estimated: false, historical: false },
  { code: "ssmsi-bf6b19b3e53b90f6594ec2e8303c5778", label: "Destructions et dégradations volontaires", available: true, estimated: false, historical: false },
  { code: "ssmsi-a2601b900aa009440624697e1d74e4a9", label: "Violences physiques hors cadre familial", available: true, estimated: true, historical: false },
  { code: "ssmsi-bdbeb8ca73503f8264dab16159795328", label: "Trafic de stupéfiants", available: true, estimated: true, historical: false }
];

const estimatedOnlyBasketAvailability = partiallyEstimatedBasketAvailability.map((category) => ({
  ...category,
  estimated: true
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

  it("provides the exposure score column when no map category is selected", () => {
    const query = buildNearbyCitySearchQuery(params);

    expect(query.text).toMatch(/null::smallint as insee_log_millesime,\s*null::numeric as category_exposure_score\s*\) map_category on true/);
  });

  it("keeps the filtered total when the requested page has no rows", async () => {
    const query = buildNearbyCitySearchQuery(params);
    const rawMapPoint = {
      inseeCode: "95584",
      name: "Seugy",
      latitude: 49.121,
      longitude: 2.391,
      distanceKm: 12.5,
      population: 1044,
      populationYear: 2023,
      comparative_index: 82,
      comparative_index_status: "available",
      basket_version: "absolute-exposure-v2",
      published_basket_category_count: 4,
      historical_published_basket_category_count: 0,
      estimated_basket_category_count: 2,
      effective_basket_category_count: 6,
      basket_index_coverage: "1",
      low_volume_cap_applied: false,
      availability_mask: 15,
      historical_availability_mask: 0,
      estimated_availability_mask: 48,
      oldest_exposure_source_year: 2025,
      comparative_index_provenance: "partially-estimated",
      categoryLabel: null,
      categoryRatePer1000: null,
      categoryPercentile: null,
      categoryExposureScore: null,
      categoryColorMode: null,
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
          map_points: [rawMapPoint]
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
      mapPoints: [{
        inseeCode: "95584",
        name: "Seugy",
        latitude: 49.121,
        longitude: 2.391,
        distanceKm: 12.5,
        population: 1044,
        populationYear: 2023,
        comparativeIndex: {
          value: 82,
          status: "available",
          provenance: "partially-estimated",
          basketVersion: "absolute-exposure-v2",
          publishedComponentCount: 4,
          historicalPublishedComponentCount: 0,
          estimatedComponentCount: 2,
          availableComponentCount: 6,
          coverageRatio: 1,
          oldestSourceYear: 2025,
          lowVolumeCapApplied: false,
          basketCategoryCount: 6,
          basketAvailability: partiallyEstimatedBasketAvailability
        },
        categoryLabel: null,
        categoryRatePer1000: null,
        categoryPercentile: null,
        categoryExposureScore: null,
        categoryColorMode: null,
        categoryCountUnit: null,
        categoryRateDenominator: "unknown",
        categoryPopulationDenominatorYear: null,
        categoryHousingDenominatorYear: null,
        categoryPublicationStatus: null,
        environmentalRisk: null
      }]
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
    expect(batchSql).toContain("metrics.comparative_index_provenance");
    expect(batchSql).toContain("metrics.oldest_exposure_source_year");
    expect(batchSql).toContain("st_dwithin");
    expect(batchSql).not.toContain("population_min");
    expect(batchSql).not.toContain("limit 10");
    expect(result.results).toEqual([]);
    expect(result.mapPoints[0].environmentalRisk).toMatchObject({
      radiusKm: 25,
      value: 40,
      status: "comparable",
      provenance: "published-only",
      scoredNeighborCount: 3,
      totalNeighborCount: 4,
      publishedOnlyNeighborCount: 3,
      historicalPublishedNeighborCount: 0,
      partiallyEstimatedNeighborCount: 0,
      estimatedOnlyNeighborCount: 0,
      oldestSourceYear: 2025
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
      provenance: "published-only",
      scoredNeighborCount: 3,
      totalNeighborCount: 3,
      publishedOnlyNeighborCount: 3,
      historicalPublishedNeighborCount: 0,
      partiallyEstimatedNeighborCount: 0,
      estimatedOnlyNeighborCount: 0,
      oldestSourceYear: 2025,
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
    expect(query.text).toContain("exposure_index_category_anchors");
    expect(query.text).toContain("category_exposure_score as map_category_exposure_score");
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
    expect(query.text).toContain("metrics.estimated_basket_category_count");
    expect(query.text).toContain("metrics.historical_published_basket_category_count");
    expect(query.text).toContain("metrics.effective_basket_category_count");
    expect(query.text).toContain("metrics.basket_index_coverage");
    expect(query.text).toContain("metrics.low_volume_cap_applied");
    expect(query.text).toContain("metrics.estimated_availability_mask");
    expect(query.text).toContain("metrics.historical_availability_mask");
    expect(query.text).toContain("metrics.oldest_exposure_source_year");
    expect(query.text).toContain("'historical_published_basket_category_count'");
    expect(query.text).toContain("'historical_availability_mask'");
    expect(query.text).toContain("'oldest_exposure_source_year'");
    expect(query.text).not.toContain("minimum_reference_cohort_size");
    expect(query.text).toContain("metrics.comparative_index_provenance");
    expect(query.text).toContain("metrics.basket_version");
    expect(query.text).not.toContain("coalesce(metrics.basket_version");
    expect(query.text).not.toContain("complement_info_nombre");
    expect(query.text).not.toContain("complement_info_taux");
  });

  it("maps temporal v2 provenance and keeps a masked selected category null", async () => {
    const selectedParams = parseNearbyCitySearchParams("95594", new URLSearchParams({
      year: "2025",
      radiusKm: "25",
      categoryCode: "ssmsi-example",
      limit: "10",
      offset: "0"
    }));
    const db = {
      query: async () => ({
        rows: [{
          origin_exists: true,
          snapshot_id: "snapshot-17",
          insee_code: "95584",
          name: "Seugy",
          department_code: "95",
          department_name: "Val-d'Oise",
          region_code: "11",
          region_name: "Ile-de-France",
          latitude: "49.121",
          longitude: "2.391",
          distance_km: "12.5",
          population: 1044,
          population_year: 2023,
          published_category_count: 0,
          total_category_count: 1,
          coverage_ratio: "0",
          comparative_index: 71,
          comparative_index_status: "available",
          basket_version: "absolute-exposure-v2",
          published_basket_category_count: 0,
          historical_published_basket_category_count: 0,
          estimated_basket_category_count: 6,
          effective_basket_category_count: 6,
          basket_index_coverage: "1",
          low_volume_cap_applied: false,
          availability_mask: 0,
          historical_availability_mask: 0,
          estimated_availability_mask: 63,
          oldest_exposure_source_year: 2025,
          comparative_index_provenance: "estimated-only",
          selected_category_label: "Exemple masqué",
          selected_category_incident_count: null,
          selected_category_rate_per_1000: null,
          selected_category_publication_status: "masked",
          selected_category_count_unit: "faits",
          selected_category_rate_denominator: "population",
          selected_category_population_denominator: "1044",
          selected_category_population_denominator_year: 2023,
          selected_category_housing_denominator: null,
          selected_category_housing_denominator_year: null,
          total_count: 1,
          map_points: []
        }],
        rowCount: 1
      })
    };

    const result = await searchNearbyCities(db as never, selectedParams);

    expect(result.results[0].comparativeIndex).toEqual({
      value: 71,
      status: "available",
      provenance: "estimated-only",
      basketVersion: "absolute-exposure-v2",
      publishedComponentCount: 0,
      historicalPublishedComponentCount: 0,
      estimatedComponentCount: 6,
      availableComponentCount: 6,
      coverageRatio: 1,
      oldestSourceYear: 2025,
      lowVolumeCapApplied: false,
      basketCategoryCount: 6,
      basketAvailability: estimatedOnlyBasketAvailability
    });
    expect(result.results[0].selectedCategory).toMatchObject({
      publicationStatus: "masked",
      incidentCount: null,
      ratePer1000: null
    });
    expect(result.results[0].selectedCategory).not.toHaveProperty("complementInfoNombre");
    expect(result.results[0].selectedCategory).not.toHaveProperty("complementInfoTaux");
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
    comparative_index: 82,
    comparative_index_status: "available",
    basket_version: "absolute-exposure-v2",
    published_basket_category_count: 4,
    historical_published_basket_category_count: 0,
    estimated_basket_category_count: 2,
    effective_basket_category_count: 6,
    basket_index_coverage: "1",
    low_volume_cap_applied: false,
    availability_mask: 15,
    historical_availability_mask: 0,
    estimated_availability_mask: 48,
    oldest_exposure_source_year: 2025,
    comparative_index_provenance: "partially-estimated",
    categoryLabel: null,
    categoryRatePer1000: null,
    categoryPercentile: null,
    categoryExposureScore: null,
    categoryColorMode: null,
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
    comparative_index: comparativeIndex,
    oldest_exposure_source_year: comparativeIndex === null ? null : 2025,
    comparative_index_provenance: comparativeIndex === null ? "unavailable" : "published-only"
  };
}
