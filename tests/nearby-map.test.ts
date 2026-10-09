import { describe, expect, it } from "vitest";

import {
  getNearbyMapPointBand,
  getNearbyMapPointColor,
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
  comparativeIndex: 97,
  comparativeIndexStatus: "comparable",
  comparativeIndexCompleteness: "low",
  categoryLabel: "Cambriolages de logement",
  categoryRatePer1000: 8.2,
  categoryPercentile: 0.84,
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

  it.each([25, 50, 100, 200] as const)(
    "uses the matching environmental score for the %i km criterion",
    (radiusKm) => {
      const environmentalPoint: NearbyMapPoint = {
        ...point,
        environmentalRisk: {
          radiusKm,
          value: 84,
          status: "comparable",
          scoredNeighborCount: 4,
          totalNeighborCount: 7,
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
      scoredNeighborCount: 2,
      totalNeighborCount: 5,
      weightedCoverageRatio: 0.4
    }],
    ["mismatched radius", {
      radiusKm: 25,
      value: 84,
      status: "comparable",
      scoredNeighborCount: 4,
      totalNeighborCount: 7,
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
