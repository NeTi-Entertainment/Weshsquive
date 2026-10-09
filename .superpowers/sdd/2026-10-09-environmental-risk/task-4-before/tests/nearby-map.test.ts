import { describe, expect, it } from "vitest";

import {
  getNearbyMapPointBand,
  getNearbyMapPointColor,
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
});
