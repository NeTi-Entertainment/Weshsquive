import { describe, expect, it } from "vitest";

import {
  comparativeIndexProvenanceLabel,
  mapComparativeIndex,
  type ComparativeIndexColumns
} from "../src/server/comparative-index";

describe("mapComparativeIndex", () => {
  it("maps the v2 provenance, counters, masks and derived completeness", () => {
    const result = mapComparativeIndex({
      comparative_index: 72,
      comparative_index_status: "comparable",
      basket_version: "residential-risk-v2",
      published_basket_category_count: 4,
      estimated_basket_category_count: 2,
      comparable_basket_category_count: 5,
      availability_mask: 15,
      estimated_availability_mask: 48,
      minimum_reference_cohort_size: 76,
      comparative_index_provenance: "partially-estimated",
      population_band: "1000-4999"
    }, 2500);

    expect(result).toMatchObject({
      value: 72,
      status: "comparable",
      provenance: "partially-estimated",
      completeness: "medium",
      basketVersion: "residential-risk-v2",
      publishedComponentCount: 4,
      estimatedComponentCount: 2,
      comparableComponentCount: 5,
      minimumReferenceCohortSize: 76,
      basketCategoryCount: 6,
      populationBand: "1000-4999"
    });
    expect(result.basketAvailability).toEqual([
      expect.objectContaining({ available: true, estimated: false }),
      expect.objectContaining({ available: true, estimated: false }),
      expect.objectContaining({ available: true, estimated: false }),
      expect.objectContaining({ available: true, estimated: false }),
      expect.objectContaining({ available: true, estimated: true }),
      expect.objectContaining({ available: true, estimated: true })
    ]);
    expect(result).not.toHaveProperty("confidence");
    expect(result).not.toHaveProperty("publishedBasketCategoryCount");
    expect(result).not.toHaveProperty("cohortSize");
  });

  it("does not invent v2 provenance or availability from missing metadata", () => {
    const incompleteRow = {
      comparative_index: 72,
      comparative_index_status: "comparable",
      basket_version: null,
      published_basket_category_count: null,
      availability_mask: null,
      population_band: "1000-4999"
    } as unknown as ComparativeIndexColumns;

    const result = mapComparativeIndex(incompleteRow, 2500);

    expect(result).toEqual({
      value: null,
      status: "insufficient-coverage",
      provenance: "unavailable",
      completeness: null,
      basketVersion: null,
      publishedComponentCount: 0,
      estimatedComponentCount: 0,
      comparableComponentCount: 0,
      minimumReferenceCohortSize: 0,
      basketCategoryCount: 6,
      basketAvailability: [
        { code: "ssmsi-78384436563146dc6167ea53b7b5e0cd", label: "Cambriolages de logement", available: false, estimated: false },
        { code: "ssmsi-74a195792dd119f60822e61df3587522", label: "Vols de véhicule", available: false, estimated: false },
        { code: "ssmsi-d3e9d2e40d72b8850d5283eb73bdc928", label: "Vols dans les véhicules", available: false, estimated: false },
        { code: "ssmsi-bf6b19b3e53b90f6594ec2e8303c5778", label: "Destructions et dégradations volontaires", available: false, estimated: false },
        { code: "ssmsi-a2601b900aa009440624697e1d74e4a9", label: "Violences physiques hors cadre familial", available: false, estimated: false },
        { code: "ssmsi-bdbeb8ca73503f8264dab16159795328", label: "Trafic de stupéfiants", available: false, estimated: false }
      ],
      populationBand: "1000-4999"
    });
  });

  it.each([
    [6, "high"],
    [5, "medium"],
    [4, "medium"],
    [3, "low"],
    [2, null]
  ] as const)("derives %s comparable components as %s completeness", (count, expected) => {
    const result = mapComparativeIndex({
      comparative_index: count >= 3 ? 50 : null,
      comparative_index_status: count >= 3 ? "comparable" : "insufficient-coverage",
      basket_version: "residential-risk-v2",
      published_basket_category_count: count,
      estimated_basket_category_count: 0,
      comparable_basket_category_count: count,
      availability_mask: 0,
      estimated_availability_mask: 0,
      minimum_reference_cohort_size: 0,
      comparative_index_provenance: count >= 3 ? "published-only" : "unavailable",
      population_band: null
    }, 2500);

    expect(result.completeness).toBe(expected);
    expect(result.basketVersion).toBe("residential-risk-v2");
  });

  it("preserves the v2 reference-cohort status", () => {
    const result = mapComparativeIndex({
      comparative_index: null,
      comparative_index_status: "reference-cohort-too-small",
      basket_version: "residential-risk-v2",
      published_basket_category_count: 2,
      estimated_basket_category_count: 2,
      comparable_basket_category_count: 2,
      availability_mask: 3,
      estimated_availability_mask: 12,
      minimum_reference_cohort_size: 0,
      comparative_index_provenance: "unavailable",
      population_band: "1000-4999"
    }, 2500);

    expect(result).toMatchObject({
      status: "reference-cohort-too-small",
      provenance: "unavailable",
      value: null
    });
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
