import { describe, expect, it } from "vitest";

import {
  comparativeIndexMetadata,
  comparativeIndexProvenanceLabel,
  mapComparativeIndex,
  type ComparativeIndexColumns
} from "../src/server/comparative-index";

const completeRow = (overrides: Partial<ComparativeIndexColumns> = {}): ComparativeIndexColumns => ({
  comparative_index: 62.4,
  comparative_index_status: "available",
  basket_version: "absolute-exposure-v1",
  published_basket_category_count: 4,
  estimated_basket_category_count: 1,
  effective_basket_category_count: 5,
  basket_index_coverage: "0.8333333333",
  availability_mask: 15,
  estimated_availability_mask: 16,
  comparative_index_provenance: "partially-estimated",
  low_volume_cap_applied: false,
  ...overrides
});

describe("absolute exposure index API mapping", () => {
  it("publishes the fixed calibration, formula, colors and guardrail", () => {
    expect(comparativeIndexMetadata).toMatchObject({
      name: "Indice d’exposition calculé par l’application",
      version: "absolute-exposure-v1",
      calibrationYear: 2025,
      colorThresholds: [10, 35, 50, 65, 85],
      guardrailCount: 10,
      guardrailCap: 35,
      temporalSmoothing: false
    });
    expect(comparativeIndexMetadata.basket.map(({ anchorRatePer1000 }) => anchorRatePer1000))
      .toEqual([16.047, 5.1964, 13.2453, 13.8213, 8.5257, 5.1832]);
  });

  it("maps score provenance, basket coverage and whether the low-volume cap changed the score", () => {
    const result = mapComparativeIndex(completeRow({
      comparative_index: 35,
      low_volume_cap_applied: true
    }));

    expect(result).toMatchObject({
      value: 35,
      status: "available",
      provenance: "partially-estimated",
      basketVersion: "absolute-exposure-v1",
      publishedComponentCount: 4,
      estimatedComponentCount: 1,
      availableComponentCount: 5,
      coverageRatio: 0.8333333333,
      lowVolumeCapApplied: true
    });
    expect(result.basketAvailability.filter((category) => category.available)).toHaveLength(5);
    expect(result.basketAvailability.find((category) => category.estimated)?.code)
      .toBe("ssmsi-a2601b900aa009440624697e1d74e4a9");
    expect(result).not.toHaveProperty("populationBand");
    expect(result).not.toHaveProperty("minimumReferenceCohortSize");
  });

  it("keeps a real zero as a published score and unknown data unavailable", () => {
    const publishedZero = mapComparativeIndex(completeRow({
      comparative_index: 0,
      published_basket_category_count: 1,
      estimated_basket_category_count: 0,
      effective_basket_category_count: 1,
      basket_index_coverage: "0.1666666667",
      availability_mask: 1,
      estimated_availability_mask: 0,
      comparative_index_provenance: "published-only"
    }));
    const unavailable = mapComparativeIndex(completeRow({
      comparative_index: null,
      comparative_index_status: "unavailable",
      published_basket_category_count: 0,
      estimated_basket_category_count: 0,
      effective_basket_category_count: 0,
      basket_index_coverage: "0",
      availability_mask: 0,
      estimated_availability_mask: 0,
      comparative_index_provenance: "unavailable"
    }));

    expect(publishedZero.value).toBe(0);
    expect(publishedZero.provenance).toBe("published-only");
    expect(publishedZero.coverageRatio).toBeCloseTo(1 / 6);
    expect(unavailable.value).toBeNull();
    expect(unavailable.provenance).toBe("unavailable");
    expect(unavailable.status).toBe("unavailable");
  });

  it("does not expose stale v2 snapshots as current scores", () => {
    const result = mapComparativeIndex(completeRow({ basket_version: "residential-risk-v2" }));

    expect(result.value).toBeNull();
    expect(result.provenance).toBe("unavailable");
    expect(result.availableComponentCount).toBe(0);
  });
});

describe("comparativeIndexProvenanceLabel", () => {
  it.each([
    ["published-only", "Données communales publiées"],
    ["partially-estimated", "Partiellement estimé"],
    ["estimated-only", "Entièrement estimé"],
    ["unavailable", "Indice indisponible"]
  ] as const)("labels %s in French", (provenance, expected) => {
    expect(comparativeIndexProvenanceLabel(provenance)).toBe(expected);
  });
});
