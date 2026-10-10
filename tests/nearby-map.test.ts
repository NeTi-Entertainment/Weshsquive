import { describe, expect, it } from "vitest";

import {
  comparativeIndexProvenanceLegend,
  formatEnvironmentalRiskNeighborProvenance,
  getComparativeIndexVisualStyle,
  getNearbyMapPointBand,
  getNearbyMapPointColor,
  getNearbyMapPointVisualStyle,
  NEARBY_MAP_UNAVAILABLE_COLOR,
  type NearbyMapPoint
} from "../src/client/nearby-map-ui";

const point: NearbyMapPoint = {
  inseeCode: "31088",
  name: "Brax",
  latitude: 43.616,
  longitude: 1.239,
  distanceKm: 5.7,
  population: 3037,
  populationYear: 2023,
  comparativeIndex: {
    value: 97,
    status: "available",
    provenance: "partially-estimated",
    basketVersion: "absolute-exposure-v1",
    publishedComponentCount: 1,
    estimatedComponentCount: 2,
    availableComponentCount: 3,
    coverageRatio: 0.5,
    lowVolumeCapApplied: false,
    basketCategoryCount: 6,
    basketAvailability: []
  },
  categoryLabel: "Cambriolages de logement",
  categoryRatePer1000: 8.2,
  categoryPercentile: 0.84,
  categoryExposureScore: null,
  categoryColorMode: "percentile",
  categoryCountUnit: "Infraction",
  categoryRateDenominator: "housing",
  categoryPopulationDenominatorYear: 2023,
  categoryHousingDenominatorYear: 2022,
  categoryPublicationStatus: "published"
};

describe("nearby map colors", () => {
  it("uses the comparative index for the default map criterion", () => {
    expect(getNearbyMapPointBand(point, "comparativeIndex")).toBe("extreme");
    expect(getNearbyMapPointColor(point, "comparativeIndex")).toBe("#781f24");
  });

  it("keeps the index hue while making score provenance visible in marker style", () => {
    const published = getComparativeIndexVisualStyle(97, "published-only");
    const partial = getComparativeIndexVisualStyle(97, "partially-estimated");
    const estimated = getComparativeIndexVisualStyle(97, "estimated-only");

    expect(partial.fillColor).toBe(published.fillColor);
    expect(estimated.fillColor).toBe(published.fillColor);
    expect(published).toMatchObject({ fillOpacity: 0.92, borderOpacity: 0.95, dashArray: null });
    expect(partial).toMatchObject({ fillOpacity: 0.68, borderOpacity: 0.9, dashArray: "6 4" });
    expect(estimated).toMatchObject({ fillOpacity: 0.48, borderOpacity: 1, dashArray: "2 2" });
    expect(estimated.borderWeight).toBeGreaterThan(partial.borderWeight);
    expect(getComparativeIndexVisualStyle(97, "unavailable").fillColor)
      .toBe(NEARBY_MAP_UNAVAILABLE_COLOR);
    expect(getComparativeIndexVisualStyle(null, "published-only").fillColor)
      .toBe(NEARBY_MAP_UNAVAILABLE_COLOR);
  });

  it("provides one legend state for each supported comparative-index provenance", () => {
    expect(comparativeIndexProvenanceLegend).toEqual([
      "published-only",
      "partially-estimated",
      "estimated-only",
      "unavailable"
    ]);
  });

  it("uses provenance styling only for the comparative-index layer", () => {
    expect(getNearbyMapPointVisualStyle(point, "comparativeIndex")?.fillColor)
      .toBe("#781f24");
    expect(getNearbyMapPointVisualStyle(point, "categoryRate")).toBeNull();
    expect(getNearbyMapPointVisualStyle(point, {
      type: "environmentalRisk",
      radiusKm: 50
    })).toBeNull();
  });

  it("formats the three environmental neighbor provenance counts separately", () => {
    expect(formatEnvironmentalRiskNeighborProvenance({
      radiusKm: 50,
      value: 62.5,
      status: "comparable",
      provenance: "partially-estimated",
      scoredNeighborCount: 6,
      totalNeighborCount: 8,
      publishedOnlyNeighborCount: 2,
      partiallyEstimatedNeighborCount: 3,
      estimatedOnlyNeighborCount: 1,
      weightedCoverageRatio: 0.75
    })).toEqual([
      "Communes voisines avec indice publié : 2",
      "Communes voisines avec indice partiellement estimé : 3",
      "Communes voisines avec indice entièrement estimé : 1"
    ]);
  });

  it("uses the comparable category percentile when a category criterion is selected", () => {
    expect(getNearbyMapPointBand(point, "categoryRate")).toBe("very-high");
    expect(getNearbyMapPointColor(point, "categoryRate")).toBe("#c84b3f");
  });

  it("renders unavailable or masked values in neutral gray", () => {
    expect(getNearbyMapPointBand({
      ...point,
      categoryPercentile: null,
      categoryPublicationStatus: "masked"
    }, "categoryRate")).toBe("");
    expect(getNearbyMapPointColor({
      ...point,
      categoryPercentile: null,
      categoryPublicationStatus: "masked"
    }, "categoryRate")).toBe("#7b8794");
  });

  it("does not color a stale numeric value when provenance says the score is unavailable", () => {
    const inconsistentPoint = {
      ...point,
      comparativeIndex: {
        ...point.comparativeIndex,
        provenance: "unavailable" as const
      }
    };

    expect(getNearbyMapPointBand(inconsistentPoint, "comparativeIndex")).toBe("");
    expect(getNearbyMapPointColor(inconsistentPoint, "comparativeIndex"))
      .toBe(NEARBY_MAP_UNAVAILABLE_COLOR);
  });

  it.each([25, 50, 100, 200] as const)(
    "uses the matching environmental score for the %i km criterion",
    (radiusKm) => {
      const environmentalPoint: NearbyMapPoint = {
        ...point,
        environmentalRisk: {
          radiusKm,
          value: 84,
          status: "comparable",
          provenance: "partially-estimated",
          scoredNeighborCount: 4,
          totalNeighborCount: 7,
          publishedOnlyNeighborCount: 2,
          partiallyEstimatedNeighborCount: 1,
          estimatedOnlyNeighborCount: 1,
          weightedCoverageRatio: 0.72
        }
      };

      expect(getNearbyMapPointBand(environmentalPoint, {
        type: "environmentalRisk",
        radiusKm
      })).toBe("very-high");
      expect(getNearbyMapPointColor(environmentalPoint, {
        type: "environmentalRisk",
        radiusKm
      })).toBe("#c84b3f");
    }
  );

  it.each([
    ["missing", null],
    ["non-comparable", {
      radiusKm: 50,
      value: 84,
      status: "insufficient-coverage",
      provenance: "unavailable",
      scoredNeighborCount: 2,
      totalNeighborCount: 5,
      publishedOnlyNeighborCount: 1,
      partiallyEstimatedNeighborCount: 1,
      estimatedOnlyNeighborCount: 0,
      weightedCoverageRatio: 0.4
    }],
    ["mismatched radius", {
      radiusKm: 25,
      value: 84,
      status: "comparable",
      provenance: "partially-estimated",
      scoredNeighborCount: 4,
      totalNeighborCount: 7,
      publishedOnlyNeighborCount: 2,
      partiallyEstimatedNeighborCount: 1,
      estimatedOnlyNeighborCount: 1,
      weightedCoverageRatio: 0.72
    }]
  ] as const)(
    "keeps an environmental point gray when its summary is %s",
    (_description, environmentalRisk) => {
      const environmentalPoint: NearbyMapPoint = {
        ...point,
        environmentalRisk
      };

      expect(getNearbyMapPointBand(environmentalPoint, {
        type: "environmentalRisk",
        radiusKm: 50
      })).toBe("");
      expect(getNearbyMapPointColor(environmentalPoint, {
        type: "environmentalRisk",
        radiusKm: 50
      })).toBe(NEARBY_MAP_UNAVAILABLE_COLOR);
    }
  );
});
