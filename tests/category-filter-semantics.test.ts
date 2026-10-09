import { describe, expect, it } from "vitest";

import {
  buildCitySearchUrl,
  defaultSearchForm
} from "../src/client/city-search-ui";
import {
  buildNearbySearchUrl,
  defaultNearbySearchForm
} from "../src/client/nearby-cities-ui";
import {
  buildCitySearchQuery,
  parseCitySearchParams
} from "../src/server/city-search";
import {
  buildNearbyCitySearchQuery,
  parseNearbyCitySearchParams
} from "../src/server/nearby-city-search";

const categoryBounds = {
  categoryIncidentMin: 0,
  categoryIncidentMax: 12,
  categoryRateMin: 0,
  categoryRateMax: 8.5
};

describe("category filter semantics", () => {
  it("rejects removed global-rate parameters in both API parsers", () => {
    expect(() => parseCitySearchParams(new URLSearchParams({
      year: "2025",
      partialRateMin: "0"
    }))).toThrow();
    expect(() => parseNearbyCitySearchParams("95584", new URLSearchParams({
      year: "2025",
      partialRateMax: "10"
    }))).toThrow();
  });

  it("returns category unit and denominator metadata in nearby results", () => {
    const query = buildNearbyCitySearchQuery({
      originInseeCode: "95584",
      year: 2025,
      radiusKm: 50,
      categoryCode: "ssmsi-cambriolages",
      limit: 100,
      offset: 0
    });

    expect(query.text).not.toMatch(/published_incident_count|partial_rate_per_1000/i);
    expect(query.text).toContain("category.count_unit as selected_category_count_unit");
    expect(query.text).toContain("category.rate_denominator as selected_category_rate_denominator");
    expect(query.text).toContain("category.insee_log_millesime as selected_category_housing_denominator_year");
  });

  it("ignores category thresholds in the main search when no category is selected", () => {
    const params = parseCitySearchParams(new URLSearchParams({
      year: "2025",
      categoryIncidentMin: "0",
      categoryIncidentMax: "12",
      categoryRateMin: "0",
      categoryRateMax: "8.5",
      limit: "50",
      offset: "0"
    }));
    const query = buildCitySearchQuery(params);

    expect(query.values).toEqual([2025, 50, 0]);
    expect(query.text).not.toContain("exists (");
    expect(query.text).not.toContain("rc_filter.");
  });

  it("filters only published values for the selected main-search category, including zero", () => {
    const query = buildCitySearchQuery({
      year: 2025,
      categoryCode: "ssmsi-cambriolages",
      ...categoryBounds,
      limit: 50,
      offset: 0
    });

    expect(query.values).toEqual([
      2025,
      "ssmsi-cambriolages",
      0,
      12,
      0,
      8.5,
      50,
      0
    ]);
    expect(query.text).toContain("rc_filter.publication_status = 'published'");
    expect(query.text).toContain("rc_filter.incident_count >= $3");
    expect(query.text).toContain("rc_filter.incident_count <= $4");
    expect(query.text).toContain("rc_filter.rate_per_1000 >= $5");
    expect(query.text).toContain("rc_filter.rate_per_1000 <= $6");
  });

  it("ignores category thresholds in nearby search when no category is selected", () => {
    const params = parseNearbyCitySearchParams(
      "95584",
      new URLSearchParams({
        year: "2025",
        radiusKm: "50",
        categoryIncidentMin: "0",
        categoryIncidentMax: "12",
        categoryRateMin: "0",
        categoryRateMax: "8.5",
        limit: "100",
        offset: "0"
      })
    );
    const query = buildNearbyCitySearchQuery(params);

    expect(query.values).toEqual(["95584", 2025, 50000, 100, 0]);
    expect(query.text).not.toContain("where nm.selected_category_publication_status = 'published'");
    expect(query.text).not.toContain("nm.selected_category_incident_count >=");
    expect(query.text).not.toContain("nm.selected_category_rate_per_1000 >=");
  });

  it("filters only published values for the selected nearby category, including zero", () => {
    const params = parseNearbyCitySearchParams(
      "95584",
      new URLSearchParams({
        year: "2025",
        radiusKm: "50",
        categoryCode: "ssmsi-cambriolages",
        categoryIncidentMin: "0",
        categoryIncidentMax: "12",
        categoryRateMin: "0",
        categoryRateMax: "8.5",
        limit: "100",
        offset: "0"
      })
    );
    const query = buildNearbyCitySearchQuery(params);

    expect(query.values).toEqual([
      "95584",
      2025,
      50000,
      "ssmsi-cambriolages",
      0,
      12,
      0,
      8.5,
      100,
      0
    ]);
    expect(query.text).toContain("nm.selected_category_publication_status = 'published'");
    expect(query.text).toContain("nm.selected_category_incident_count >= $5");
    expect(query.text).toContain("nm.selected_category_incident_count <= $6");
    expect(query.text).toContain("nm.selected_category_rate_per_1000 >= $7");
    expect(query.text).toContain("nm.selected_category_rate_per_1000 <= $8");
    expect(query.text).toContain("nm.selected_category_rate_denominator in ('population', 'housing')");
  });
});

describe("category filter URLs", () => {
  it("omits main-search category thresholds when the category is empty", () => {
    const url = buildCitySearchUrl({
      ...defaultSearchForm,
      categoryIncidentMin: "0",
      categoryIncidentMax: "12",
      categoryRateMin: "0",
      categoryRateMax: "8.5"
    });
    const params = new URL(url, "http://localhost").searchParams;

    expect(params.get("categoryCode")).toBeNull();
    expect(params.has("categoryIncidentMin")).toBe(false);
    expect(params.has("categoryIncidentMax")).toBe(false);
    expect(params.has("categoryRateMin")).toBe(false);
    expect(params.has("categoryRateMax")).toBe(false);
  });

  it("keeps main-search thresholds when a category is selected", () => {
    const url = buildCitySearchUrl({
      ...defaultSearchForm,
      categoryCode: "ssmsi-cambriolages",
      categoryIncidentMin: "0"
    });

    expect(url).toContain("categoryCode=ssmsi-cambriolages");
    expect(url).toContain("categoryIncidentMin=0");
  });

  it("omits nearby category thresholds when the category is empty", () => {
    const url = buildNearbySearchUrl("95584", 2025, {
      ...defaultNearbySearchForm,
      categoryIncidentMin: "0",
      categoryIncidentMax: "12",
      categoryRateMin: "0",
      categoryRateMax: "8.5"
    });
    const params = new URL(url, "http://localhost").searchParams;

    expect(params.has("categoryIncidentMin")).toBe(false);
    expect(params.has("categoryIncidentMax")).toBe(false);
    expect(params.has("categoryRateMin")).toBe(false);
    expect(params.has("categoryRateMax")).toBe(false);
  });

  it("keeps nearby thresholds when a category is selected", () => {
    const url = buildNearbySearchUrl("95584", 2025, {
      ...defaultNearbySearchForm,
      categoryCode: "ssmsi-cambriolages",
      categoryIncidentMin: "0"
    });

    expect(url).toContain("categoryCode=ssmsi-cambriolages");
    expect(url).toContain("categoryIncidentMin=0");
  });

  it("serializes the independent map color category", () => {
    const url = buildNearbySearchUrl("95584", 2025, {
      ...defaultNearbySearchForm,
      mapCategoryCode: "ssmsi-cambriolages"
    });

    expect(url).toContain("mapCategoryCode=ssmsi-cambriolages");
    expect(url).not.toContain("categoryCode=ssmsi-cambriolages");
  });
});
