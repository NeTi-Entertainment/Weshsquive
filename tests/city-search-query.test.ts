import { describe, expect, it } from "vitest";

import { buildCitySearchQuery, parseCitySearchParams } from "../src/server/city-search";

describe("parseCitySearchParams", () => {
  it("parses supported filters and applies safe paging defaults", () => {
    const parsed = parseCitySearchParams(
      new URLSearchParams({
        year: "2025",
        regionCode: "11",
        departmentCode: "95",
        commune: "Seugy",
        populationMin: "1000",
        populationMax: "10000",
        comparativeIndexMax: "100",
        categoryCode: "ssmsi-cambriolages",
        categoryIncidentMin: "2",
        categoryRateMax: "10.5",
        sortBy: "categoryRatePer1000",
        sortDirection: "desc",
        sortCategoryCode: "ssmsi-violences",
        limit: "500",
        offset: "25"
      })
    );

    expect(parsed).toEqual({
      year: 2025,
      regionCode: "11",
      departmentCode: "95",
      commune: "Seugy",
      populationMin: 1000,
      populationMax: 10000,
      comparativeIndexMax: 100,
      categoryCode: "ssmsi-cambriolages",
      categoryIncidentMin: 2,
      categoryRateMax: 10.5,
      sortBy: "categoryRatePer1000",
      sortDirection: "desc",
      sortCategoryCode: "ssmsi-violences",
      limit: 200,
      offset: 25
    });
  });

  it("rejects requests without a year", () => {
    expect(() => parseCitySearchParams(new URLSearchParams())).toThrow("year");
  });
});

describe("buildCitySearchQuery", () => {
  it("exposes coverage without any heterogeneous global aggregate", () => {
    const query = buildCitySearchQuery({ year: 2025, limit: 25, offset: 0 });

    expect(query.text).toContain("metrics.published_category_count");
    expect(query.text).toContain("metrics.total_category_count");
    expect(query.text).not.toMatch(/published_incident_count|partial_rate_per_1000|sum\s*\(/i);
    expect(query.text).toContain("rc.count_unit");
    expect(query.text).toContain("rc.rate_denominator");
    expect(query.text).toContain("rc.insee_pop_millesime");
    expect(query.text).toContain("rc.insee_log_millesime");
  });

  it("builds a parameterized search with geography and comparative-index filters", () => {
    const query = buildCitySearchQuery({
      year: 2025,
      regionCode: "11",
      departmentCode: "95",
      commune: "Seugy",
      populationMin: 1000,
      populationMax: 10000,
      comparativeIndexMin: 30,
      comparativeIndexMax: 70,
      limit: 50,
      offset: 10
    });

    expect(query.values).toEqual([
      2025,
      "11",
      "95",
      "%Seugy%",
      1000,
      10000,
      30,
      70,
      50,
      10
    ]);
    expect(query.text).toContain("search_metrics_active");
    expect(query.text).toContain("search_metrics_city_year_category");
    expect(query.text).not.toContain("coalesce(metrics.population, c.reference_population)");
    expect(query.text).not.toContain("with raw_categories as");
    expect(query.text).not.toContain("city_year_category_metrics");
    expect(query.text).toContain("cm.region_code = $2");
    expect(query.text).toContain("cm.department_code = $3");
    expect(query.text).toContain("cm.name ilike $4");
    expect(query.text).toContain("cm.population is not null");
    expect(query.text).toContain("cm.population >= $5");
    expect(query.text).toContain("cm.population <= $6");
    expect(query.text).not.toContain("coalesce(cm.population, 0)");
    expect(query.text).not.toMatch(/partial_rate_per_1000|published_incident_count/i);
    expect(query.text).toContain("cm.comparative_index <= $8");
    expect(query.text).toContain("limit $9");
    expect(query.text).toContain("offset $10");
  });

  it("filters a selected category by published values only", () => {
    const query = buildCitySearchQuery({
      year: 2025,
      categoryCode: "ssmsi-cambriolages",
      categoryIncidentMin: 3,
      categoryRateMax: 12,
      limit: 25,
      offset: 0
    });

    expect(query.values).toEqual([2025, "ssmsi-cambriolages", 3, 12, 25, 0]);
    expect(query.text).toContain("exists (");
    expect(query.text).toContain("rc_filter.category_code = $2");
    expect(query.text).toContain("rc_filter.publication_status = 'published'");
    expect(query.text).toContain("rc_filter.incident_count >= $3");
    expect(query.text).toContain("rc_filter.rate_per_1000 <= $4");
    expect(query.text).toContain("rc_filter.rate_denominator in ('population', 'housing')");
    expect(query.text).not.toContain("ssmsi-cambriolages");
  });

  it("rejects the removed aggregate sorts", () => {
    expect(() => parseCitySearchParams(new URLSearchParams({
      year: "2025",
      sortBy: "publishedIncidentCount"
    }))).toThrow();
    expect(() => parseCitySearchParams(new URLSearchParams({
      year: "2025",
      partialRateMin: "0"
    }))).toThrow();
  });

  it("orders by the comparative index with a deterministic fallback", () => {
    const query = buildCitySearchQuery({
      year: 2025,
      sortBy: "comparativeIndex",
      sortDirection: "desc",
      limit: 25,
      offset: 0
    });

    expect(query.values).toEqual([2025, 25, 0]);
    expect(query.text).toContain(
      "order by comparative_index desc nulls last, name asc, insee_code asc"
    );
  });

  it("orders by a category metric through a parameterized category code", () => {
    const query = buildCitySearchQuery({
      year: 2025,
      sortBy: "categoryIncidentCount",
      sortDirection: "asc",
      sortCategoryCode: "ssmsi-cambriolages",
      limit: 25,
      offset: 0
    });

    expect(query.values).toEqual([2025, "ssmsi-cambriolages", 25, 0]);
    expect(query.text).toContain("category.category_code = $2");
    expect(query.text).toContain(
      "order by sort_category_incident_count asc nulls last, name asc, insee_code asc"
    );
    expect(query.text).not.toContain("ssmsi-cambriolages");
  });

  it("keeps unknown-base values out of per-category rate sorting", () => {
    const query = buildCitySearchQuery({
      year: 2025,
      sortBy: "categoryRatePer1000",
      sortDirection: "desc",
      sortCategoryCode: "ssmsi-cambriolages",
      limit: 25,
      offset: 0
    });

    expect(query.text).toContain("category.count_unit is not null");
    expect(query.text).toContain("category.rate_denominator in ('population', 'housing')");
    expect(query.text).toContain("order by sort_category_rate_per_1000 desc nulls last");
  });

  it("reads comparative scores and their cohort data from the derived view", () => {
    const query = buildCitySearchQuery({ year: 2025, limit: 25, offset: 0 });

    expect(query.text).toContain("search_metrics_city_year_comparative");
    expect(query.text).not.toContain("city_year_comparative_metrics");
    expect(query.text).toContain("metrics.comparative_index");
    expect(query.text).toContain("metrics.comparative_index_confidence");
    expect(query.text).toContain("metrics.cohort_size");
    expect(query.text).not.toContain("percent_rank()");
    expect(query.text).not.toMatch(/published_incident_count|partial_rate_per_1000/i);
  });
});
