import { describe, expect, it } from "vitest";

import {
  buildNearbySearchUrl,
  createDefaultNearbySearchForm,
  defaultNearbySearchForm,
  getNearbyMapCriterion,
  selectNearbyMapCriterion
} from "../src/client/nearby-cities-ui";

describe("nearby search context state", () => {
  it("creates a fresh default form when the origin or year changes", () => {
    const first = createDefaultNearbySearchForm();
    first.populationMin = "1200";
    first.categoryCode = "ssmsi-cambriolages";

    const next = createDefaultNearbySearchForm();

    expect(next).toEqual(defaultNearbySearchForm);
    expect(next).not.toBe(defaultNearbySearchForm);
    expect(next).not.toBe(first);
  });
});

describe("nearby map criterion state", () => {
  it("clears the category when selecting an environmental radius", () => {
    const selected = selectNearbyMapCriterion(
      {
        ...defaultNearbySearchForm,
        mapCategoryCode: "ssmsi-cambriolages"
      },
      { type: "environmentalRisk", radiusKm: 50 }
    );

    expect(selected.mapCategoryCode).toBe("");
    expect(selected.mapEnvironmentalRadiusKm).toBe("50");
    expect(getNearbyMapCriterion(selected)).toEqual({
      type: "environmentalRisk",
      radiusKm: 50
    });
  });

  it("clears the environmental radius when selecting a category", () => {
    const selected = selectNearbyMapCriterion(
      {
        ...defaultNearbySearchForm,
        mapEnvironmentalRadiusKm: "100"
      },
      { type: "categoryRate" },
      "ssmsi-cambriolages"
    );

    expect(selected.mapEnvironmentalRadiusKm).toBe("");
    expect(selected.mapCategoryCode).toBe("ssmsi-cambriolages");
    expect(getNearbyMapCriterion(selected)).toEqual({ type: "categoryRate" });
  });

  it("leaves both map-specific filters empty in default mode", () => {
    const selected = selectNearbyMapCriterion(
      {
        ...defaultNearbySearchForm,
        mapCategoryCode: "ssmsi-cambriolages",
        mapEnvironmentalRadiusKm: "25"
      },
      { type: "comparativeIndex" }
    );

    expect(selected.mapCategoryCode).toBe("");
    expect(selected.mapEnvironmentalRadiusKm).toBe("");
    expect(getNearbyMapCriterion(selected)).toEqual({ type: "comparativeIndex" });
  });

  it("serializes the selected environmental radius and omits it in default mode", () => {
    const environmentalUrl = buildNearbySearchUrl("95584", 2025, {
      ...defaultNearbySearchForm,
      mapEnvironmentalRadiusKm: "50"
    });
    const defaultUrl = buildNearbySearchUrl("95584", 2025, defaultNearbySearchForm);

    expect(new URL(environmentalUrl, "http://localhost").searchParams.get("environmentalRadiusKm"))
      .toBe("50");
    expect(new URL(defaultUrl, "http://localhost").searchParams.has("environmentalRadiusKm"))
      .toBe(false);
  });
});
