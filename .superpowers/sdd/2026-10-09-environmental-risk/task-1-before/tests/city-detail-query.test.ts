import { describe, expect, it, vi } from "vitest";

import {
  buildCityDetailQuery,
  buildCityComparisonQuery,
  buildCityHistoryQuery,
  getCityDetail
} from "../src/server/city-detail";

describe("city detail queries", () => {
  it("compares territories by the same category, count unit, and known rate base", () => {
    const query = buildCityDetailQuery({ inseeCode: "95584", year: 2025 });

    expect(query.text).toContain("search_metrics_active");
    expect(query.text).toContain("search_metrics_city_year_comparative");
    expect(query.text).toContain("search_metrics_city_year_category");
    expect(query.text).toContain("as snapshot_id");
    expect(query.text).not.toContain("population_history ph");
    expect(query.text).not.toContain("c.reference_population");
    expect(query.text).not.toContain("city_year_comparative_metrics");
    expect(query.text).not.toContain("city_year_category_metrics");
    expect(query.text).toContain("count_unit");
    expect(query.text).toContain("rate_denominator");
    expect(query.text).toContain("category_code");
    const comparisonQuery = buildCityComparisonQuery({ inseeCode: "95584", year: 2025 }, "17");
    expect(comparisonQuery.values).toEqual(["95584", 2025, "17"]);
    expect(comparisonQuery.text).toContain("publication_status = 'published'");
    expect(comparisonQuery.text).toContain("search_metrics_city_year_category");
    expect(comparisonQuery.text).not.toContain("city_year_category_metrics");
    expect(comparisonQuery.text).toContain("sum(");
    expect(comparisonQuery.text).toContain("published_city_count");
    expect(comparisonQuery.text).toContain("total_city_count");
    expect(comparisonQuery.text).toContain("when scope.scope = 'commune' then max(target.rate_per_1000)");
    expect(comparisonQuery.text).toContain("count(scope.city_insee_code)::integer as total_city_count");
    expect(comparisonQuery.text).not.toContain("count(observation.city_insee_code)::integer as total_city_count");
    expect(comparisonQuery.text).toContain("observation.count_unit is not distinct from target.count_unit");
    expect(comparisonQuery.text).toContain("observation.rate_denominator = target.rate_denominator");
    expect(comparisonQuery.text).toContain("insee_pop_millesime");
    expect(comparisonQuery.text).toContain("insee_log_millesime");
    expect(query.text).not.toMatch(/published_incident_count|partial_rate_per_1000/i);
  });

  it("returns history observations for each category with base and denominator vintage", () => {
    const query = buildCityHistoryQuery("95584", "17");

    expect(query.values).toEqual(["95584", "17"]);
    expect(query.text).toContain("snapshot_id = $2");
    expect(query.text).toContain("search_metrics_city_year_category");
    expect(query.text).not.toContain("city_year_category_metrics");
    expect(query.text).toContain("category_code");
    expect(query.text).toContain("count_unit");
    expect(query.text).toContain("rate_denominator");
    expect(query.text).toContain("insee_pop_millesime");
    expect(query.text).toContain("insee_log_millesime");
    expect(query.text).toContain("publication_status");
    expect(query.text).not.toMatch(/published_incident_count|partial_rate_per_1000/i);
  });

  it("uses the detail query snapshot for history and comparisons", async () => {
    const db = {
      query: vi.fn(async (text: string, _values: unknown) => {
        if (text.includes("select tc.*")) {
          return {
            rows: [{
              snapshot_id: "42",
              insee_code: "95584",
              name: "Seugy",
              department_code: "95",
              department_name: "Val-d'Oise",
              region_code: "11",
              region_name: "Ile-de-France",
              latitude: null,
              longitude: null,
              population: 1044,
              population_year: 2023,
              published_category_count: 1,
              total_category_count: 1,
              coverage_ratio: "1",
              comparative_index: null,
              comparative_index_status: "insufficient-coverage",
              comparative_index_confidence: null,
              basket_version: "residential-risk-v1",
              published_basket_category_count: 0,
              availability_mask: 0,
              cohort_size: 0,
              population_band: "1000-4999",
              categories: []
            }],
            rowCount: 1
          };
        }

        if (text.includes("from scope_cities")) {
          return { rows: [], rowCount: 0 };
        }

        return { rows: [], rowCount: 0 };
      })
    };

    await getCityDetail(db as never, { inseeCode: "95584", year: 2025 });

    expect(db.query).toHaveBeenCalledTimes(3);
    expect(db.query.mock.calls[1]?.[1]).toEqual(["95584", "42"]);
    expect(db.query.mock.calls[2]?.[1]).toEqual(["95584", 2025, "42"]);
  });
});
