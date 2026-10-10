import { describe, expect, it } from "vitest";

import { defaultSearchForm } from "../src/client/city-search-ui";
import {
  buildNationalMapUrl,
  formatNationalMapResultCount,
  getNationalMapFeatureColor,
  getNationalMapFeatureVisualStyle,
  getNationalMapLevel,
  getNationalMapPointColor,
  multiPolygonToLeafletPositions
} from "../src/client/france-map-ui";

const bounds = { west: -1.2, south: 44.2, east: 0.3, north: 45.1 };

describe("national map UI helpers", () => {
  it("converts multipolygon coordinates while preserving holes and separate parts", () => {
    expect(multiPolygonToLeafletPositions({
      type: "MultiPolygon",
      coordinates: [
        [
          [[1, 2], [3, 4], [5, 6], [1, 2]],
          [[1.5, 2.5], [2, 3], [1.5, 2.5]]
        ],
        [[[10, 20], [30, 40], [10, 20]]]
      ]
    })).toEqual([
      [
        [[2, 1], [4, 3], [6, 5], [2, 1]],
        [[2.5, 1.5], [3, 2], [2.5, 1.5]]
      ],
      [[[20, 10], [40, 30], [20, 10]]]
    ]);
  });

  it("uses the shared region, department and commune zoom levels", () => {
    expect([5, 6, 7, 8].map(getNationalMapLevel)).toEqual([
      "region",
      "department",
      "department",
      "commune"
    ]);
  });

  it("serializes active search filters, map criterion and viewport", () => {
    const url = buildNationalMapUrl({
      ...defaultSearchForm,
      year: "2025",
      regionCode: "75",
      departmentCode: "33",
      commune: "Bordeaux",
      populationMin: "1000",
      comparativeIndexMax: "70",
      categoryCode: "filter-category",
      categoryIncidentMin: "2",
      categoryRateMax: "15.5"
    }, bounds, 8, { type: "categoryRate", categoryCode: "map-category" });
    const params = new URL(url, "http://localhost").searchParams;

    expect(params.get("year")).toBe("2025");
    expect(params.get("regionCode")).toBe("75");
    expect(params.get("departmentCode")).toBe("33");
    expect(params.get("commune")).toBe("Bordeaux");
    expect(params.get("populationMin")).toBe("1000");
    expect(params.get("comparativeIndexMax")).toBe("70");
    expect(params.get("categoryCode")).toBe("filter-category");
    expect(params.get("categoryIncidentMin")).toBe("2");
    expect(params.get("categoryRateMax")).toBe("15.5");
    expect(params.get("criterion")).toBe("categoryRate");
    expect(params.get("mapCategoryCode")).toBe("map-category");
    expect(params.get("west")).toBe("-1.20000");
    expect(params.get("zoom")).toBe("8");
    expect(params.has("offset")).toBe(false);
    expect(params.has("limit")).toBe(false);
  });

  it("omits category thresholds when no filter category is selected", () => {
    const url = buildNationalMapUrl({
      ...defaultSearchForm,
      categoryIncidentMin: "4",
      categoryRateMax: "12"
    }, bounds, 8, { type: "comparativeIndex" });
    const params = new URL(url, "http://localhost").searchParams;

    expect(params.has("categoryIncidentMin")).toBe(false);
    expect(params.has("categoryRateMax")).toBe(false);
    expect(params.get("criterion")).toBe("comparativeIndex");
  });

  it("serializes the environmental radius without a category", () => {
    const url = buildNationalMapUrl(defaultSearchForm, bounds, 8, {
      type: "environmentalRisk",
      radiusKm: 100
    });
    const params = new URL(url, "http://localhost").searchParams;

    expect(params.get("criterion")).toBe("environmentalRisk");
    expect(params.get("environmentalRadiusKm")).toBe("100");
    expect(params.has("mapCategoryCode")).toBe(false);
  });

  it.each([
    [{ type: "salePrice", propertyType: "house" } as const, "salePrice", "house"],
    [{ type: "rentPrice", propertyType: "apartment" } as const, "rentPrice", "apartment"]
  ])("serializes property layer %o", (criterion, expectedCriterion, expectedType) => {
    const url = buildNationalMapUrl(defaultSearchForm, bounds, 8, criterion);
    const params = new URL(url, "http://localhost").searchParams;

    expect(params.get("criterion")).toBe(expectedCriterion);
    expect(params.get("marketPropertyType")).toBe(expectedType);
    expect(params.has("mapCategoryCode")).toBe(false);
    expect(params.has("environmentalRadiusKm")).toBe(false);
  });

  it("uses the selected commune indicator color and gray for unavailable values", () => {
    const point = {
      inseeCode: "33063",
      name: "Bordeaux",
      latitude: 44.84,
      longitude: -0.58,
      population: 260958,
      populationYear: 2023,
      comparativeIndex: {
        value: 54,
        status: "available" as const,
        provenance: "published-only" as const,
        basketVersion: "absolute-exposure-v1",
        publishedComponentCount: 6,
        estimatedComponentCount: 0,
        availableComponentCount: 6,
        coverageRatio: 1,
        lowVolumeCapApplied: false,
        basketCategoryCount: 6,
        basketAvailability: []
      },
      categoryLabel: "Cambriolages",
      categoryIncidentCount: 12,
      categoryRatePer1000: "8.2",
      categoryPercentile: "0.9",
      categoryExposureScore: null,
      categoryColorMode: "percentile" as const,
      categoryCountUnit: "infractions",
      categoryRateDenominator: "housing" as const,
      categoryPopulationDenominator: null,
      categoryPopulationDenominatorYear: null,
      categoryHousingDenominator: 12000,
      categoryHousingDenominatorYear: 2023,
      categoryPublicationStatus: "published" as const,
      environmentalRisk: null,
      propertyMarket: null
    };

    expect(getNationalMapPointColor(point, { type: "categoryRate", categoryCode: "B" }))
      .toBe("#c84b3f");
    expect(getNationalMapPointColor(point, { type: "comparativeIndex" })).toBe("#eca154");
    expect(getNationalMapFeatureVisualStyle({ type: "commune", point }, {
      type: "comparativeIndex"
    })).toMatchObject({ fillColor: "#eca154", dashArray: null });
    expect(getNationalMapFeatureVisualStyle({
      type: "commune",
      point: {
        ...point,
        comparativeIndex: { ...point.comparativeIndex, provenance: "partially-estimated" }
      }
    }, { type: "comparativeIndex" })).toMatchObject({ fillOpacity: 0.68, dashArray: "6 4" });
    expect(getNationalMapFeatureVisualStyle({ type: "commune", point }, {
      type: "categoryRate",
      categoryCode: "B"
    })).toBeNull();
    expect(getNationalMapFeatureVisualStyle({ type: "department" }, {
      type: "comparativeIndex"
    })).toBeNull();
    expect(getNationalMapPointColor({ ...point, categoryPublicationStatus: "masked" }, {
      type: "categoryRate",
      categoryCode: "B"
    })).toBe("#7b8794");
    expect(getNationalMapPointColor({
      ...point,
      categoryPercentile: "0.99",
      categoryExposureScore: "35",
      categoryColorMode: "absolute-exposure"
    }, { type: "categoryRate", categoryCode: "basket-category" })).toBe("#8fd19e");
    expect(getNationalMapPointColor({
      ...point,
      comparativeIndex: { ...point.comparativeIndex, value: null, status: "unavailable", provenance: "unavailable" }
    }, {
      type: "comparativeIndex"
    })).toBe("#7b8794");
    expect(getNationalMapFeatureColor({ type: "region" }, {
      type: "environmentalRisk",
      radiusKm: 25
    })).toBe("#526a7b");
    expect(getNationalMapPointColor({
      ...point,
      propertyMarket: {
        kind: "sale",
        propertyType: "house",
        valuePerM2: "3500",
        lowerBoundPerM2: null,
        upperBoundPerM2: null,
        sampleCount: 12,
        nationalPercentile: "0.95",
        status: "published",
        sourceSystem: "dvf-geolocated",
        sourceYear: 2025
      }
    }, { type: "salePrice", propertyType: "house" })).toBe("#4b4fa3");
    expect(getNationalMapFeatureColor({ type: "department" }, {
      type: "rentPrice",
      propertyType: "apartment"
    })).toBe("#526a7b");
  });

  it("uses accurate singular and plural labels for visible map features", () => {
    expect(formatNationalMapResultCount({
      level: "region",
      snapshotId: null,
      groups: [{} as never],
      communes: []
    })).toBe("1 région dans l’emprise visible");
    expect(formatNationalMapResultCount({
      level: "department",
      snapshotId: null,
      groups: [{} as never, {} as never],
      communes: []
    })).toBe("2 départements dans l’emprise visible");
    expect(formatNationalMapResultCount({
      level: "commune",
      snapshotId: null,
      groups: [],
      communes: [{} as never],
      requiresZoom: false
    })).toBe("1 commune dans l’emprise visible");
  });

  it("asks for a closer zoom when commune polygons exceed the rendering limit", () => {
    expect(formatNationalMapResultCount({
      level: "commune",
      snapshotId: "17",
      groups: [],
      communes: [],
      requiresZoom: true
    })).toBe("Zoomez davantage pour afficher les communes de cette emprise");
  });
});
