import { describe, expect, it } from "vitest";

import {
  buildPropertyMarketSelection,
  mapPropertyMarketMetric,
  type RawPropertyMarketColumns
} from "@/server/property-market";

function rawMetric(overrides: Partial<RawPropertyMarketColumns> = {}): RawPropertyMarketColumns {
  return {
    property_market_year_available: true,
    property_market_year: 2025,
    property_market_kind: "sale",
    property_market_property_type: "apartment",
    property_market_value_per_m2: "3250.5000",
    property_market_lower_bound_per_m2: null,
    property_market_upper_bound_per_m2: null,
    property_market_sample_count: 8,
    property_market_national_percentile: "0.7500000000",
    property_market_display_status: "published",
    property_market_source_system: "dvf-geolocated",
    ...overrides
  };
}

describe("property market server contract", () => {
  it("builds an indexed same-year selection without fallback", () => {
    const fragment = buildPropertyMarketSelection({
      yearPlaceholder: "$5",
      kindPlaceholder: "$6",
      propertyTypePlaceholder: "$7"
    });

    expect(fragment).toContain("market.year = $5");
    expect(fragment).toContain("market.metric_kind = $6");
    expect(fragment).toContain("market.property_type = $7");
    expect(fragment).toContain("availability.year = $5");
    expect(fragment).not.toMatch(/max\s*\(\s*year\s*\)/i);
  });

  it("maps a published metric without converting PostgreSQL decimals", () => {
    expect(mapPropertyMarketMetric(rawMetric(), { kind: "sale", propertyType: "apartment" }))
      .toEqual({
        kind: "sale",
        propertyType: "apartment",
        valuePerM2: "3250.5000",
        lowerBoundPerM2: null,
        upperBoundPerM2: null,
        sampleCount: 8,
        nationalPercentile: "0.7500000000",
        status: "published",
        sourceSystem: "dvf-geolocated",
        sourceYear: 2025
      });
  });

  it("keeps an unavailable commune distinct from an unavailable year", () => {
    expect(mapPropertyMarketMetric(rawMetric({
      property_market_year: null,
      property_market_kind: null,
      property_market_property_type: null,
      property_market_value_per_m2: null,
      property_market_sample_count: null,
      property_market_national_percentile: null,
      property_market_display_status: null,
      property_market_source_system: null
    }), { kind: "rent", propertyType: "house" })).toMatchObject({
      kind: "rent",
      propertyType: "house",
      status: "no-data",
      valuePerM2: null,
      sourceYear: null
    });

    expect(mapPropertyMarketMetric(rawMetric({
      property_market_year_available: false,
      property_market_year: null,
      property_market_kind: null,
      property_market_property_type: null,
      property_market_value_per_m2: null,
      property_market_sample_count: null,
      property_market_national_percentile: null,
      property_market_display_status: null,
      property_market_source_system: null
    }), { kind: "rent", propertyType: "house" })).toMatchObject({
      status: "year-unavailable",
      valuePerM2: null,
      sourceYear: null
    });
  });

  it.each([
    "source-uncovered",
    "no-data",
    "insufficient-sample",
    "non-communal-estimate",
    "insufficient-quality",
    "invalid-value"
  ] as const)("maps gray status %s without leaking a value", (status) => {
    const metric = mapPropertyMarketMetric(rawMetric({
      property_market_value_per_m2: null,
      property_market_national_percentile: null,
      property_market_display_status: status
    }), { kind: "sale", propertyType: "all" });
    expect(metric.status).toBe(status);
    expect(metric.valuePerM2).toBeNull();
    expect(metric.nationalPercentile).toBeNull();
  });
});
