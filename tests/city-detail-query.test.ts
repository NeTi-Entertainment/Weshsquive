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
    expect(query.text).toContain("tm.estimated_basket_category_count");
    expect(query.text).toContain("tm.effective_basket_category_count");
    expect(query.text).toContain("tm.basket_index_coverage");
    expect(query.text).toContain("tm.low_volume_cap_applied");
    expect(query.text).toContain("tm.estimated_availability_mask");
    expect(query.text).toContain("tm.comparative_index_provenance");
    expect(query.text).toContain("tm.basket_version");
    expect(query.text).not.toContain("coalesce(tm.basket_version");
    expect(query.text).not.toContain("complement_info_nombre");
    expect(query.text).not.toContain("complement_info_taux");
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

  it("uses the detail query snapshot for history, comparisons, and environmental risk", async () => {
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
              comparative_index_status: "unavailable",
              basket_version: "absolute-exposure-v1",
              published_basket_category_count: 0,
              estimated_basket_category_count: 0,
              effective_basket_category_count: 0,
              basket_index_coverage: "0",
              low_volume_cap_applied: false,
              availability_mask: 0,
              estimated_availability_mask: 0,
              comparative_index_provenance: "unavailable",
              categories: [{
                code: "ssmsi-example",
                label: "Exemple masqué",
                incidentCount: null,
                ratePer1000: null,
                countUnit: "faits",
                rateDenominator: "population",
                populationDenominator: 1044,
                populationDenominatorYear: 2023,
                housingDenominator: null,
                housingDenominatorYear: null,
                publicationStatus: "masked"
              }]
            }],
            rowCount: 1
          };
        }

        if (text.includes("from scope_cities")) {
          return { rows: [], rowCount: 0 };
        }

        if (text.includes("environmental_radii")) {
          return {
            rows: [25, 50, 100, 200].map((radius_km) => ({
              radius_km,
              target_coordinates_available: false,
              target_insee_code: "95584",
              neighbor_insee_code: null,
              distance_km: null,
              comparative_index: null
            })),
            rowCount: 4
          };
        }

        return { rows: [], rowCount: 0 };
      })
    };

    const detail = await getCityDetail(db as never, { inseeCode: "95584", year: 2025 });

    expect(db.query).toHaveBeenCalledTimes(4);
    expect(db.query.mock.calls[1]?.[1]).toEqual(["95584", "42"]);
    expect(db.query.mock.calls[2]?.[1]).toEqual(["95584", 2025, "42"]);
    expect(db.query.mock.calls[3]?.[1]).toEqual(["95584", 2025, "42"]);
    expect(db.query.mock.calls[3]?.[0]).toContain("environmental_radii");
    expect(detail?.environmentalRisk.map(({ radiusKm, status }) => [radiusKm, status])).toEqual([
      [25, "coordinates-unavailable"],
      [50, "coordinates-unavailable"],
      [100, "coordinates-unavailable"],
      [200, "coordinates-unavailable"]
    ]);
    expect(detail?.comparativeIndex).toMatchObject({
      basketVersion: "absolute-exposure-v1",
      status: "unavailable",
      provenance: "unavailable",
      publishedComponentCount: 0,
      estimatedComponentCount: 0,
      availableComponentCount: 0,
      coverageRatio: 0,
      lowVolumeCapApplied: false
    });
    expect(detail?.categories[0]).toMatchObject({
      publicationStatus: "masked",
      incidentCount: null,
      ratePer1000: null
    });
    expect(detail?.categories[0]).not.toHaveProperty("complementInfoNombre");
    expect(detail?.categories[0]).not.toHaveProperty("complementInfoTaux");
  });
});
