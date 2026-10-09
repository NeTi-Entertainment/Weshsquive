import { describe, expect, it, vi } from "vitest";

import {
  buildNationalMapQuery,
  getNationalMapLevel,
  parseNationalMapParams,
  searchNationalMap
} from "../src/server/national-map";

function mapParams(overrides: Record<string, string> = {}) {
  return new URLSearchParams({
    year: "2025",
    zoom: "5",
    west: "-5",
    south: "41",
    east: "10",
    north: "52",
    criterion: "comparativeIndex",
    ...overrides
  });
}

describe("national map parameters", () => {
  it.each([
    [5, "region"],
    [6, "department"],
    [7, "department"],
    [8, "commune"]
  ] as const)("uses the %s zoom hierarchy", (zoom, expected) => {
    expect(getNationalMapLevel(zoom)).toBe(expected);
    expect(parseNationalMapParams(mapParams({ zoom: String(zoom) })).level).toBe(expected);
  });

  const invalidBounds: Array<Record<string, string>> = [
    { west: "10", east: "-5" },
    { south: "52", north: "41" },
    { west: "-181" },
    { north: "91" }
  ];
  it.each(invalidBounds)("rejects invalid viewport bounds %o", (bounds) => {
    expect(() => parseNationalMapParams(mapParams(bounds))).toThrow();
  });

  it("requires a category for category-rate coloring", () => {
    expect(() => parseNationalMapParams(mapParams({ criterion: "categoryRate" }))).toThrow();
  });

  it("requires a supported radius for environmental coloring", () => {
    expect(() => parseNationalMapParams(mapParams({
      criterion: "environmentalRisk",
      environmentalRadiusKm: "30"
    }))).toThrow();
  });

  it.each([
    ["salePrice", "all"],
    ["salePrice", "apartment"],
    ["salePrice", "house"],
    ["rentPrice", "apartment"],
    ["rentPrice", "house"]
  ])("accepts %s with property type %s", (criterion, marketPropertyType) => {
    expect(parseNationalMapParams(mapParams({ criterion, marketPropertyType })))
      .toMatchObject({ criterion, marketPropertyType });
  });

  const invalidPropertyMarketParams: Array<Record<string, string>> = [
    { criterion: "salePrice" },
    { criterion: "rentPrice" },
    { criterion: "rentPrice", marketPropertyType: "all" },
    { criterion: "salePrice", marketPropertyType: "castle" },
    { criterion: "comparativeIndex", marketPropertyType: "house" }
  ];
  it.each(invalidPropertyMarketParams)("rejects invalid property market parameters %o", (params) => {
    expect(() => parseNationalMapParams(mapParams(params))).toThrow();
  });

  it("builds navigation-only regional and departmental queries", () => {
    const region = buildNationalMapQuery(parseNationalMapParams(mapParams({ zoom: "5" })));
    const department = buildNationalMapQuery(parseNationalMapParams(mapParams({ zoom: "6" })));

    expect(region.values).toEqual([-5, 41, 10, 52]);
    expect(region.text).toContain("join visible_centers on visible_centers.code = visible_groups.code");
    expect(region.text).not.toContain("search_metrics_city_year_comparative");
    expect(region.text).not.toContain("search_metrics_city_year_category");
    expect(department.text).toContain("join departments d on d.code = territory_bounds.code");
    expect(department.text).not.toContain("comparative_index");
  });

  it("recenters a selected department independently of the current viewport", () => {
    const params = parseNationalMapParams(mapParams({
      zoom: "5",
      departmentCode: "971"
    }));
    const query = buildNationalMapQuery(params);

    expect(params.level).toBe("department");
    expect(query.text).not.toContain("c.longitude between $1 and $3");
    expect(query.text).toContain("c.department_code = $1");
  });

  it("returns a selected region with stable full-region bounds", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams({
      regionCode: "01"
    })));

    expect(query.text).not.toContain("c.longitude between $1 and $3");
    expect(query.text).toContain("visible_groups");
    expect(query.text).toContain("join visible_groups on visible_groups.code = c.region_code");
    expect(query.text).toContain("min(c.longitude) as west");
    expect(query.text).toContain("avg(longitude) as longitude");
  });

  it("uses visible commune centers with full territory bounds and valid dimension joins", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams()));

    expect(query.text).toContain("join regions r on r.code = territory_bounds.code");
    expect(query.text).not.toContain("join join regions");
    expect(query.text).toContain("from visible_cities\n  group by code");
    expect(query.text).toContain("join territory_bounds on territory_bounds.code = visible_groups.code");
    expect(query.text).toContain("min(c.longitude) as west");
    expect(query.text).toContain("max(c.latitude) as north");
  });

  it("filters commune points to the viewport and ranks only matching published cohorts", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "categoryRate",
      mapCategoryCode: "ssmsi-example"
    })));

    expect(query.values).toEqual([-5, 41, 10, 52, 2025, "ssmsi-example"]);
    expect(query.text).toContain("c.longitude between $1 and $3");
    expect(query.text).toContain("c.latitude between $2 and $4");
    expect(query.text).toContain("partition by metrics.population_band, category.count_unit, category.rate_denominator");
    expect(query.text).toContain("category.publication_status = 'published'");
    expect(query.text).toContain("category.rate_denominator in ('population', 'housing')");
    expect(query.text).toContain("metrics.snapshot_id = active_snapshot.snapshot_id");
  });

  it("joins indexed property metrics only for visible communes in the selected year", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "salePrice",
      marketPropertyType: "house"
    })));

    expect(query.values).toEqual([-5, 41, 10, 52, 2025, "sale", "house"]);
    expect(query.text).toContain("property_market.year = $5");
    expect(query.text).toContain("property_market.metric_kind = $6");
    expect(query.text).toContain("property_market.property_type = $7");
    expect(query.text).toContain("c.longitude between $1 and $3");
    expect(query.text).not.toMatch(/max\s*\(\s*year\s*\)/i);

    const regionQuery = buildNationalMapQuery(parseNationalMapParams(mapParams({
      criterion: "salePrice",
      marketPropertyType: "house"
    })));
    expect(regionQuery.text).not.toContain("property_market_metrics");
  });

  it("maps a published property metric without affecting legacy fields", async () => {
    const db = {
      query: vi.fn().mockResolvedValue({
        rows: [rawCityRow({
          property_market_year_available: true,
          property_market_year: 2025,
          property_market_kind: "rent",
          property_market_property_type: "apartment",
          property_market_value_per_m2: "13.2500",
          property_market_lower_bound_per_m2: "11.0000",
          property_market_upper_bound_per_m2: "15.5000",
          property_market_sample_count: 42,
          property_market_national_percentile: "0.8000000000",
          property_market_display_status: "published",
          property_market_source_system: "anil-rent-map"
        })],
        rowCount: 1
      })
    };
    const params = parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "rentPrice",
      marketPropertyType: "apartment"
    }));

    const result = await searchNationalMap(db as never, params);

    expect(result.level).toBe("commune");
    if (result.level !== "commune") throw new Error("Expected commune points");
    expect(result.points[0]).toMatchObject({
      comparativeIndex: 54,
      propertyMarket: {
        kind: "rent",
        propertyType: "apartment",
        valuePerM2: "13.2500",
        lowerBoundPerM2: "11.0000",
        upperBoundPerM2: "15.5000",
        sampleCount: 42,
        nationalPercentile: "0.8000000000",
        status: "published",
        sourceSystem: "anil-rent-map",
        sourceYear: 2025
      }
    });
  });

  it("maps commune result rows without replacing missing values with zero", async () => {
    const db = {
      query: async () => ({
        rows: [{
          snapshot_id: "17",
          insee_code: "33063",
          name: "Bordeaux",
          department_code: "33",
          department_name: "Gironde",
          region_code: "75",
          region_name: "Nouvelle-Aquitaine",
          latitude: "44.8378",
          longitude: "-0.5792",
          population: null,
          population_year: null,
          comparative_index: null,
          comparative_index_status: "population-unavailable",
          comparative_index_confidence: null,
          basket_version: "residential-risk-v1",
          published_basket_category_count: 0,
          cohort_size: 0,
          availability_mask: 0,
          population_band: null,
          published_category_count: 0,
          total_category_count: 15,
          coverage_ratio: "0",
          category_label: "Vols",
          incident_count: null,
          rate_per_1000: null,
          count_unit: "victimes",
          rate_denominator: "unknown",
          insee_pop: null,
          insee_pop_millesime: null,
          insee_log: null,
          insee_log_millesime: null,
          publication_status: "masked",
          category_percentile: null
        }],
        rowCount: 1
      })
    };
    const params = parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "categoryRate",
      mapCategoryCode: "ssmsi-example"
    }));

    const result = await searchNationalMap(db as never, params);

    expect(result.level).toBe("commune");
    if (result.level !== "commune") throw new Error("Expected commune points");
    expect(result.points[0]).toMatchObject({
      inseeCode: "33063",
      population: null,
      comparativeIndex: null,
      categoryPublicationStatus: "masked",
      categoryIncidentCount: null,
      categoryRatePer1000: null
    });
  });

  it("returns navigation groups without statistical fields", async () => {
    const db = {
      query: vi.fn().mockResolvedValue({
        rows: [{
          snapshot_id: "17",
          code: "75",
          name: "Nouvelle-Aquitaine",
          parent_code: null,
          parent_name: null,
          latitude: "45.5",
          longitude: "0.2",
          commune_count: 1200,
          west: "-1.8",
          south: "42.7",
          east: "2.6",
          north: "46.9"
        }],
        rowCount: 1
      })
    };
    const params = parseNationalMapParams(mapParams());

    const result = await searchNationalMap(db as never, params);

    expect(result).toMatchObject({ level: "region", snapshotId: "17", points: [] });
    if (result.level === "commune") throw new Error("Expected navigation groups");
    expect(result.groups[0]).toEqual({
      type: "region",
      code: "75",
      name: "Nouvelle-Aquitaine",
      parentCode: null,
      parentName: null,
      latitude: 45.5,
      longitude: 0.2,
      communeCount: 1200,
      bounds: { west: -1.8, south: 42.7, east: 2.6, north: 46.9 }
    });
    expect(result.groups[0]).not.toHaveProperty("comparativeIndex");
    expect(result.groups[0]).not.toHaveProperty("crimeCount");
  });

  it("batches environmental scores for visible commune points on the same snapshot", async () => {
    const db = {
      query: vi.fn()
        .mockResolvedValueOnce({ rows: [rawCityRow()], rowCount: 1 })
        .mockResolvedValueOnce({
          rows: [20, 40, 80].map((comparativeIndex, index) => ({
            target_insee_code: "33063",
            target_coordinates_available: true,
            neighbor_insee_code: `3300${index}`,
            distance_km: String(index + 1),
            comparative_index: comparativeIndex
          })),
          rowCount: 3
        })
    };
    const params = parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "environmentalRisk",
      environmentalRadiusKm: "25"
    }));

    const result = await searchNationalMap(db as never, params);

    expect(db.query).toHaveBeenCalledTimes(2);
    expect(db.query.mock.calls[1]?.[1]).toEqual([["33063"], 2025, "17", 25000]);
    expect(result.level).toBe("commune");
    if (result.level !== "commune") throw new Error("Expected commune points");
    expect(result.points[0]?.environmentalRisk).toMatchObject({
      radiusKm: 25,
      status: "comparable",
      scoredNeighborCount: 3,
      totalNeighborCount: 3
    });
  });

  it("does not calculate environmental scores for region or department groups", async () => {
    const db = { query: vi.fn().mockResolvedValue({ rows: [], rowCount: 0 }) };
    const params = parseNationalMapParams(mapParams({
      criterion: "environmentalRisk",
      environmentalRadiusKm: "50"
    }));

    await searchNationalMap(db as never, params);

    expect(db.query).toHaveBeenCalledTimes(1);
  });
});

function rawCityRow(overrides: Record<string, unknown> = {}) {
  return {
    snapshot_id: "17",
    insee_code: "33063",
    name: "Bordeaux",
    department_code: "33",
    department_name: "Gironde",
    region_code: "75",
    region_name: "Nouvelle-Aquitaine",
    latitude: "44.8378",
    longitude: "-0.5792",
    population: 260958,
    population_year: 2023,
    comparative_index: 54,
    comparative_index_status: "comparable",
    comparative_index_confidence: "high",
    basket_version: "residential-risk-v1",
    published_basket_category_count: 6,
    cohort_size: 150,
    availability_mask: 63,
    population_band: "100000-plus",
    published_category_count: 12,
    total_category_count: 15,
    coverage_ratio: "0.8",
    category_label: null,
    incident_count: null,
    rate_per_1000: null,
    count_unit: null,
    rate_denominator: "unknown" as const,
    insee_pop: null,
    insee_pop_millesime: null,
    insee_log: null,
    insee_log_millesime: null,
    publication_status: null,
    category_percentile: null,
    ...overrides
  };
}
