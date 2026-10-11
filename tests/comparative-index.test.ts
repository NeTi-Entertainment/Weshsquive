import { describe, expect, it } from "vitest";

import {
  comparativeIndexMetadata,
  comparativeIndexProvenanceLabel,
  exposureComponentSourceLabel,
  mapComparativeIndex,
  type ComparativeIndexColumns
} from "../src/server/comparative-index";

const completeRow = (overrides: Partial<ComparativeIndexColumns> = {}): ComparativeIndexColumns => ({
  comparative_index: 62.4,
  comparative_index_status: "available",
  basket_version: "absolute-exposure-v2",
  published_basket_category_count: 2,
  historical_published_basket_category_count: 2,
  estimated_basket_category_count: 1,
  effective_basket_category_count: 5,
  basket_index_coverage: "0.8333333333",
  availability_mask: 3,
  historical_availability_mask: 12,
  estimated_availability_mask: 16,
  oldest_exposure_source_year: 2023,
  comparative_index_provenance: "partially-estimated",
  low_volume_cap_applied: false,
  ...overrides
});

describe("exposure component source labels", () => {
  it.each([
    ["current-published", 2025, "Donnée communale publiée en 2025"],
    ["historical-published", 2024, "Donnée communale historique publiée en 2024"],
    ["department-masked-average", 2025, "Estimation issue du complément départemental 2025"],
    ["unavailable", null, "Aucune composante exploitable pour l’indice"],
    [null, null, null]
  ] as const)("labels %s without reclassifying masked target values", (source, sourceYear, expected) => {
    expect(exposureComponentSourceLabel(source, sourceYear, 2025)).toBe(expected);
  });
});

describe("absolute exposure index API mapping", () => {
  it("publishes the fixed calibration, formula, colors and guardrail", () => {
    expect(comparativeIndexMetadata).toMatchObject({
      name: "Indice d’exposition calculé par l’application",
      version: "absolute-exposure-v2",
      calibrationYear: 2025,
      colorThresholds: [10, 35, 50, 65, 85],
      guardrailCount: 10,
      guardrailCap: 35,
      temporalSmoothing: false,
      maxCommunalLookbackYears: 3,
      minimumComponents: 3
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
      basketVersion: "absolute-exposure-v2",
      publishedComponentCount: 2,
      historicalPublishedComponentCount: 2,
      estimatedComponentCount: 1,
      availableComponentCount: 5,
      coverageRatio: 0.8333333333,
      oldestSourceYear: 2023,
      lowVolumeCapApplied: true
    });
    expect(result.basketAvailability.filter((category) => category.available)).toHaveLength(5);
    expect(result.basketAvailability.find((category) => category.estimated)?.code)
      .toBe("ssmsi-a2601b900aa009440624697e1d74e4a9");
    expect(result).not.toHaveProperty("populationBand");
    expect(result).not.toHaveProperty("minimumReferenceCohortSize");
  });

  it("keeps a real zero as a published score when the minimum component coverage is met", () => {
    const publishedZero = mapComparativeIndex(completeRow({
      comparative_index: 0,
      published_basket_category_count: 3,
      historical_published_basket_category_count: 0,
      estimated_basket_category_count: 0,
      effective_basket_category_count: 3,
      basket_index_coverage: "0.5",
      availability_mask: 7,
      historical_availability_mask: 0,
      estimated_availability_mask: 0,
      oldest_exposure_source_year: 2025,
      comparative_index_provenance: "published-only"
    }));
    const insufficient = mapComparativeIndex(completeRow({
      comparative_index: null,
      comparative_index_status: "unavailable",
      published_basket_category_count: 1,
      historical_published_basket_category_count: 1,
      estimated_basket_category_count: 0,
      effective_basket_category_count: 2,
      basket_index_coverage: "0.3333333333",
      availability_mask: 1,
      historical_availability_mask: 2,
      estimated_availability_mask: 0,
      oldest_exposure_source_year: 2024,
      comparative_index_provenance: "unavailable"
    }));

    expect(publishedZero.value).toBe(0);
    expect(publishedZero.provenance).toBe("published-only");
    expect(publishedZero.coverageRatio).toBe(0.5);
    expect(insufficient).toMatchObject({
      value: null,
      status: "unavailable",
      provenance: "unavailable",
      publishedComponentCount: 1,
      historicalPublishedComponentCount: 1,
      availableComponentCount: 2,
      oldestSourceYear: 2024
    });
    expect(insufficient.basketAvailability.filter((category) => category.available)).toHaveLength(2);
  });

  it.each([
    ["published-only", 3, 0, 0, 7, 0, 0],
    ["historical-published", 0, 3, 0, 0, 7, 0],
    ["partially-estimated", 1, 1, 1, 1, 2, 4],
    ["estimated-only", 0, 0, 3, 0, 0, 7]
  ] as const)("maps %s provenance with separate source counts", (
    provenance,
    current,
    historical,
    estimated,
    currentMask,
    historicalMask,
    estimatedMask
  ) => {
    const result = mapComparativeIndex(completeRow({
      comparative_index: 45,
      comparative_index_status: "available",
      comparative_index_provenance: provenance,
      published_basket_category_count: current,
      historical_published_basket_category_count: historical,
      estimated_basket_category_count: estimated,
      effective_basket_category_count: current + historical + estimated,
      basket_index_coverage: String((current + historical + estimated) / 6),
      availability_mask: currentMask,
      historical_availability_mask: historicalMask,
      estimated_availability_mask: estimatedMask,
      oldest_exposure_source_year: historical > 0 ? 2023 : 2025
    }));

    expect(result).toMatchObject({
      value: 45,
      status: "available",
      provenance,
      publishedComponentCount: current,
      historicalPublishedComponentCount: historical,
      estimatedComponentCount: estimated,
      availableComponentCount: current + historical + estimated
    });
  });

  it("does not expose stale v2 snapshots as current scores", () => {
    const result = mapComparativeIndex(completeRow({ basket_version: "absolute-exposure-v1" }));

    expect(result.value).toBeNull();
    expect(result.provenance).toBe("unavailable");
    expect(result.availableComponentCount).toBe(0);
  });
});

describe("comparativeIndexProvenanceLabel", () => {
  it.each([
    ["published-only", "Données communales 2025"],
    ["historical-published", "Données communales complétées par l’historique"],
    ["partially-estimated", "Partiellement estimé"],
    ["estimated-only", "Entièrement estimé"],
    ["unavailable", "Indisponible"]
  ] as const)("labels %s in French", (provenance, expected) => {
    expect(comparativeIndexProvenanceLabel(provenance, 2025)).toBe(expected);
  });
});
