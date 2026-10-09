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
      mapPoints: [mapPoint]
    });
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
