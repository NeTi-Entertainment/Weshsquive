import { describe, expect, it } from "vitest";

import {
  EXPOSURE_INDEX_ANCHORS,
  applyLowVolumeExposureCap,
  normalizeExposureRate,
  getExposureRiskBand
} from "../src/shared/exposure-index";

describe("absolute exposure index", () => {
  it("normalizes each basket category against its fixed 2025 anchor", () => {
    expect(EXPOSURE_INDEX_ANCHORS.map(({ code, anchorRatePer1000, denominator }) =>
      normalizeExposureRate(code, anchorRatePer1000, denominator)
    )).toEqual([100, 100, 100, 100, 100, 100]);
    expect(normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, 8.0235, "housing")).toBe(50);
    expect(normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[1].code, 10.3928, "population")).toBe(100);
  });

  it("gives a category the same risk score regardless of commune population", () => {
    const sameRate = 8.0235;
    const smallCityScore = normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, sameRate, "housing");
    const largeCityScore = normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, sameRate, "housing");

    expect(smallCityScore).toBe(largeCityScore);
  });

  it("keeps invalid or unknown-base values unavailable and caps high rates at 100", () => {
    expect(normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, null, "housing")).toBeNull();
    expect(normalizeExposureRate("unreferenced-category", 2, "population")).toBeNull();
    expect(normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, 1, "population")).toBeNull();
    expect(normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, 0, "housing")).toBe(0);
    expect(normalizeExposureRate(EXPOSURE_INDEX_ANCHORS[0].code, 32.094, "housing")).toBe(100);
  });

  it.each([
    [0, "very-low"],
    [10, "very-low"],
    [10.1, "low"],
    [35, "low"],
    [35.1, "medium"],
    [50, "medium"],
    [50.1, "high"],
    [65, "high"],
    [65.1, "very-high"],
    [85, "very-high"],
    [85.1, "extreme"],
    [100, "extreme"]
  ] as const)("maps score %s to the fixed %s risk band", (score, expectedBand) => {
    expect(getExposureRiskBand(score)).toBe(expectedBand);
  });

  it("applies the green cap only with published comparable infraction counts and sufficient coverage", () => {
    const infractions = {
      burglary: { published: true, countUnit: "Infraction", count: 4 },
      degradation: { published: true, countUnit: "Infraction", count: 5 },
      publishedComponentCount: 5
    };

    expect(applyLowVolumeExposureCap(36.3, infractions)).toEqual({ value: 35, applied: true });
    expect(applyLowVolumeExposureCap(34.2, infractions)).toEqual({ value: 34.2, applied: false });
    expect(applyLowVolumeExposureCap(80, {
      ...infractions,
      burglary: { ...infractions.burglary, published: false }
    })).toEqual({ value: 80, applied: false });
    expect(applyLowVolumeExposureCap(80, {
      ...infractions,
      degradation: { ...infractions.degradation, countUnit: "Victime" }
    })).toEqual({ value: 80, applied: false });
    expect(applyLowVolumeExposureCap(80, {
      ...infractions,
      degradation: { ...infractions.degradation, count: 6 },
      publishedComponentCount: 4
    })).toEqual({ value: 80, applied: false });
  });
});
