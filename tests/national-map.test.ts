import { describe, expect, it, vi } from "vitest";

import {
  buildNationalMapQuery,
  getNationalMapLevel,
  parseNationalMapParams,
  searchNationalMap
} from "../src/server/national-map";

const partiallyEstimatedBasketAvailability = [
  { code: "ssmsi-78384436563146dc6167ea53b7b5e0cd", label: "Cambriolages de logement", available: true, estimated: false },
  { code: "ssmsi-74a195792dd119f60822e61df3587522", label: "Vols de véhicule", available: true, estimated: false },
  { code: "ssmsi-d3e9d2e40d72b8850d5283eb73bdc928", label: "Vols dans les véhicules", available: true, estimated: false },
  { code: "ssmsi-bf6b19b3e53b90f6594ec2e8303c5778", label: "Destructions et dégradations volontaires", available: true, estimated: false },
  { code: "ssmsi-a2601b900aa009440624697e1d74e4a9", label: "Violences physiques hors cadre familial", available: true, estimated: true },
  { code: "ssmsi-bdbeb8ca73503f8264dab16159795328", label: "Trafic de stupéfiants", available: true, estimated: true }
];

const unavailableBasketAvailability = partiallyEstimatedBasketAvailability.map((category) => ({
  ...category,
  available: false,
  estimated: false
}));

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

  it("provides the exposure score column when no category layer is selected", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams({ zoom: "8" })));

    expect(query.text).toMatch(/null::text as publication_status,\s*null::numeric as category_exposure_score\s*\) map_category on true/);
  });

  it("selects communes by visible polygon intersection and ranks matching published cohorts", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "categoryRate",
      mapCategoryCode: "ssmsi-example"
    })));

    expect(query.values).toEqual([-5, 41, 10, 52, 2025, "ssmsi-example", 8]);
    expect(query.text).toContain("ST_Intersects(c.boundary_geom, ST_MakeEnvelope($1, $2, $3, $4, 4326))");
    expect(query.text).not.toContain("c.longitude between $1 and $3");
    expect(query.text).toContain("ST_SimplifyPreserveTopology");
    expect(query.text).toContain("ST_AsGeoJSON(ST_Multi(ST_Transform(");
    expect(query.text).toContain("ST_Transform(c.boundary_geom, 3857)");
    expect(query.text).toContain("count(*) over() as visible_feature_count");
    expect(query.text).toContain("limit 2501");
    expect(query.text).toContain("partition by metrics.population_band, category.count_unit, category.rate_denominator");
    expect(query.text).toContain("category.publication_status = 'published'");
    expect(query.text).toContain("category.rate_denominator in ('population', 'housing')");
    expect(query.text).toContain("metrics.snapshot_id = active_snapshot.snapshot_id");
    expect(query.text).toContain("metrics.estimated_basket_category_count");
    expect(query.text).toContain("metrics.effective_basket_category_count");
    expect(query.text).toContain("metrics.basket_index_coverage");
    expect(query.text).toContain("metrics.low_volume_cap_applied");
    expect(query.text).toContain("metrics.estimated_availability_mask");
    expect(query.text).toContain("exposure_index_category_anchors");
    expect(query.text).not.toContain("minimum_reference_cohort_size");
    expect(query.text).toContain("metrics.comparative_index_provenance");
    expect(query.text).toContain("metrics.basket_version");
    expect(query.text).not.toContain("coalesce(metrics.basket_version");
    expect(query.text).not.toContain("complement_info_nombre");
    expect(query.text).not.toContain("complement_info_taux");
  });

  it("requests a closer zoom instead of returning a partial list above the polygon limit", async () => {
    const rows = Array.from({ length: 2501 }, (_, index) => rawCityRow({
      insee_code: String(index).padStart(5, "0"),
      visible_feature_count: "2501"
    }));
    const db = { query: vi.fn().mockResolvedValue({ rows, rowCount: rows.length }) };
    const params = parseNationalMapParams(mapParams({ zoom: "8" }));

    const result = await searchNationalMap(db as never, params);

    expect(result).toMatchObject({
      level: "commune",
      snapshotId: "17",
      communes: [],
      requiresZoom: true
    });
  });

  it("joins indexed property metrics only for visible communes in the selected year", () => {
    const query = buildNationalMapQuery(parseNationalMapParams(mapParams({
      zoom: "8",
      criterion: "salePrice",
      marketPropertyType: "house"
    })));

    expect(query.values).toEqual([-5, 41, 10, 52, 2025, "sale", "house", 8]);
    expect(query.text).toContain("property_market.year = $5");
    expect(query.text).toContain("property_market.metric_kind = $6");
    expect(query.text).toContain("property_market.property_type = $7");
    expect(query.text).toContain("ST_Intersects(c.boundary_geom, ST_MakeEnvelope($1, $2, $3, $4, 4326))");
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
    if (result.level !== "commune") throw new Error("Expected commune polygons");
    expect(result.communes[0].comparativeIndex).toEqual({
      value: 54,
      status: "available",
      provenance: "partially-estimated",
      basketVersion: "absolute-exposure-v1",
      publishedComponentCount: 4,
      estimatedComponentCount: 2,
      availableComponentCount: 6,
      coverageRatio: 1,
      lowVolumeCapApplied: false,
      basketCategoryCount: 6,
      basketAvailability: partiallyEstimatedBasketAvailability
    });
    expect(result.communes[0].propertyMarket).toEqual({
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
    });
  });

  it("maps commune result rows without replacing missing values with zero", async () => {
    const db = {
      query: async () => ({
        rows: [{
          snapshot_id: "17",
          visible_feature_count: "1",
          boundary_geojson: JSON.stringify({
            type: "MultiPolygon",
            coordinates: [[[[2, 46], [2, 46.01], [2.01, 46.01], [2.01, 46], [2, 46]]]]
          }),
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
          comparative_index_status: "unavailable",
          basket_version: null,
          published_basket_category_count: 0,
          estimated_basket_category_count: 0,
          effective_basket_category_count: 0,
          basket_index_coverage: "0",
          low_volume_cap_applied: false,
          availability_mask: 0,
          estimated_availability_mask: 0,
          comparative_index_provenance: "unavailable",
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
          category_percentile: null,
          category_exposure_score: null,
          category_color_mode: "percentile"
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
    if (result.level !== "commune") throw new Error("Expected commune polygons");
    expect(result.communes[0].comparativeIndex).toEqual({
      value: null,
      status: "unavailable",
      provenance: "unavailable",
      basketVersion: null,
      publishedComponentCount: 0,
      estimatedComponentCount: 0,
      availableComponentCount: 0,
      coverageRatio: 0,
      lowVolumeCapApplied: false,
      basketCategoryCount: 6,
      basketAvailability: unavailableBasketAvailability
    });
    expect(result.communes[0]).toMatchObject({
      inseeCode: "33063",
      population: null,
      geometry: {
        type: "MultiPolygon",
        coordinates: [[[[2, 46], [2, 46.01], [2.01, 46.01], [2.01, 46], [2, 46]]]]
      },
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

    expect(result).toMatchObject({ level: "region", snapshotId: "17", communes: [] });
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

  it("batches environmental scores for visible commune polygons on the same snapshot", async () => {
    const db = {
      query: vi.fn()
        .mockResolvedValueOnce({ rows: [rawCityRow()], rowCount: 1 })
        .mockResolvedValueOnce({
          rows: [20, 40, 80].map((comparativeIndex, index) => ({
            target_insee_code: "33063",
            target_coordinates_available: true,
            neighbor_insee_code: `3300${index}`,
            distance_km: String(index + 1),
            comparative_index: comparativeIndex,
            comparative_index_provenance: "partially-estimated"
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
    expect(db.query.mock.calls[1]?.[0]).toContain("metrics.comparative_index_provenance");
    expect(result.level).toBe("commune");
    if (result.level !== "commune") throw new Error("Expected commune polygons");
    expect(result.communes[0]?.environmentalRisk).toMatchObject({
      radiusKm: 25,
      status: "comparable",
      provenance: "partially-estimated",
      scoredNeighborCount: 3,
      totalNeighborCount: 3,
      publishedOnlyNeighborCount: 0,
      partiallyEstimatedNeighborCount: 3,
      estimatedOnlyNeighborCount: 0
    });
  });

  it("returns all matched polygons when the viewport is within the feature limit", async () => {
    const rows = Array.from({ length: 2500 }, (_, index) => rawCityRow({
      insee_code: String(index).padStart(5, "0"),
      visible_feature_count: "2500"
    }));
    const db = { query: vi.fn().mockResolvedValue({ rows, rowCount: rows.length }) };
    const params = parseNationalMapParams(mapParams({ zoom: "8" }));

    const result = await searchNationalMap(db as never, params);

    expect(result.level).toBe("commune");
    if (result.level !== "commune") throw new Error("Expected commune polygons");
    expect(result.requiresZoom).toBe(false);
    expect(result.communes).toHaveLength(2500);
    expect(result.communes[0].geometry.type).toBe("MultiPolygon");
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
    visible_feature_count: "1",
    boundary_geojson: JSON.stringify({
      type: "MultiPolygon",
      coordinates: [[[[2, 46], [2, 46.01], [2.01, 46.01], [2.01, 46], [2, 46]]]]
    }),
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
    comparative_index_status: "available",
    basket_version: "absolute-exposure-v1",
    published_basket_category_count: 4,
    estimated_basket_category_count: 2,
    effective_basket_category_count: 6,
    basket_index_coverage: "1",
    low_volume_cap_applied: false,
    availability_mask: 15,
    estimated_availability_mask: 48,
    comparative_index_provenance: "partially-estimated",
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
    category_exposure_score: null,
    category_color_mode: null,
    ...overrides
  };
}
