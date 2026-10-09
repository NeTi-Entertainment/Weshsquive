import { describe, expect, it } from "vitest";

import {
  formatPropertyMarketInterval,
  formatPropertyMarketValue,
  getPropertyMarketColor,
  propertyMarketStatusLabel
} from "@/client/property-market-ui";
import type { PropertyMarketMetric } from "@/shared/property-market";

function metric(overrides: Partial<PropertyMarketMetric> = {}): PropertyMarketMetric {
  return {
    kind: "sale",
    propertyType: "apartment",
    valuePerM2: "3250.5",
    lowerBoundPerM2: null,
    upperBoundPerM2: null,
    sampleCount: 8,
    nationalPercentile: "0.5",
    status: "published",
    sourceSystem: "dvf-geolocated",
    sourceYear: 2025,
    ...overrides
  } as PropertyMarketMetric;
}

describe("property market UI", () => {
  it.each([
    ["0", "#d7eef8"],
    ["0.2001", "#9bd6ea"],
    ["0.4001", "#52abc8"],
    ["0.6001", "#2777b5"],
    ["0.8001", "#4b4fa3"],
    ["0.9501", "#692b83"]
  ])("colors percentile %s with %s", (nationalPercentile, color) => {
    expect(getPropertyMarketColor(metric({ nationalPercentile }))).toBe(color);
  });

  it.each([
    "source-uncovered",
    "no-data",
    "insufficient-sample",
    "non-communal-estimate",
    "insufficient-quality",
    "invalid-value",
    "year-unavailable"
  ] as const)("uses gray for %s", (status) => {
    expect(getPropertyMarketColor(metric({
      status,
      valuePerM2: null,
      nationalPercentile: null
    }))).toBe("#7b8794");
  });

  it("formats sale medians and monthly advertised rents with exact units", () => {
    expect(formatPropertyMarketValue(metric())).toContain("€/m²");
    expect(formatPropertyMarketValue(metric({
      kind: "rent",
      propertyType: "house",
      valuePerM2: "12.75",
      lowerBoundPerM2: "11.25",
      upperBoundPerM2: "14.5",
      sourceSystem: "anil-rent-map"
    }))).toContain("€/m²/mois");
    expect(formatPropertyMarketInterval(metric({
      kind: "rent",
      propertyType: "house",
      lowerBoundPerM2: "11.25",
      upperBoundPerM2: "14.5"
    }))).toContain("11,25");
  });

  it("uses comprehensible labels for every gray state", () => {
    expect(propertyMarketStatusLabel("source-uncovered")).toBe("Zone non couverte par la source");
    expect(propertyMarketStatusLabel("insufficient-sample")).toBe("Échantillon de ventes insuffisant");
    expect(propertyMarketStatusLabel("non-communal-estimate")).toBe("Estimation établie sur une maille plus large");
    expect(propertyMarketStatusLabel("insufficient-quality")).toBe("Qualité statistique insuffisante");
    expect(propertyMarketStatusLabel("year-unavailable")).toBe("Données immobilières indisponibles pour cette année");
  });
});
