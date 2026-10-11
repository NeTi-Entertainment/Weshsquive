import { describe, expect, it } from "vitest";

import {
  EXPOSURE_ALERT_LABEL,
  getMultipleHighExposureAlert
} from "../src/shared/exposure-alert";
import { EXPOSURE_INDEX_ANCHORS } from "../src/shared/exposure-index";

describe("multiple high exposure alert", () => {
  const [firstCategory, secondCategory, thirdCategory] = EXPOSURE_INDEX_ANCHORS;
  const twoHighComponents = [
    {
      code: firstCategory.code,
      label: firstCategory.label,
      exposureScore: 85,
      exposureSourceYear: 2024,
      exposureProvenance: "historical-published" as const
    },
    {
      code: secondCategory.code,
      label: secondCategory.label,
      exposureScore: 65,
      exposureSourceYear: 2025,
      exposureProvenance: "current-published" as const
    }
  ];

  it.each([
    [34.1, true],
    [35, true],
    [35.1, false]
  ])("only flags two high components at or below an index of 35 (%s)", (globalScore, shouldFlag) => {
    const alert = getMultipleHighExposureAlert(globalScore, twoHighComponents);

    expect(alert !== null).toBe(shouldFlag);
  });

  it("does not flag one high component when the global index is moderate", () => {
    expect(getMultipleHighExposureAlert(35, [twoHighComponents[0]])).toBeNull();
  });

  it("flags two usable high components and retains their source details", () => {
    expect(getMultipleHighExposureAlert(34.1, [
      {
        code: firstCategory.code,
        label: firstCategory.label,
        exposureScore: 85,
        exposureSourceYear: 2024,
        exposureProvenance: "historical-published"
      },
      {
        code: secondCategory.code,
        label: secondCategory.label,
        exposureScore: 65,
        exposureSourceYear: 2025,
        exposureProvenance: "department-masked-average"
      }
    ])).toEqual({
      label: EXPOSURE_ALERT_LABEL,
      components: [
        {
          code: firstCategory.code,
          label: firstCategory.label,
          score: 85,
          sourceYear: 2024,
          provenance: "historical-published"
        },
        {
          code: secondCategory.code,
          label: secondCategory.label,
          score: 65,
          sourceYear: 2025,
          provenance: "department-masked-average"
        }
      ]
    });
  });

  it("does not flag a single high component", () => {
    expect(getMultipleHighExposureAlert(20, [{
      code: firstCategory.code,
      label: firstCategory.label,
      exposureScore: 99,
      exposureSourceYear: 2025,
      exposureProvenance: "current-published"
    }])).toBeNull();
  });

  it("ignores scores below 65, unavailable scores, and categories outside the basket", () => {
    expect(getMultipleHighExposureAlert(20, [
      {
        code: firstCategory.code,
        label: firstCategory.label,
        exposureScore: 64.999,
        exposureSourceYear: 2025,
        exposureProvenance: "current-published"
      },
      {
        code: secondCategory.code,
        label: secondCategory.label,
        exposureScore: 100,
        exposureSourceYear: 2025,
        exposureProvenance: "unavailable"
      },
      {
        code: "outside-basket",
        label: "Catégorie hors panier",
        exposureScore: 100,
        exposureSourceYear: 2025,
        exposureProvenance: "current-published"
      },
      {
        code: thirdCategory.code,
        label: thirdCategory.label,
        exposureScore: null,
        exposureSourceYear: null,
        exposureProvenance: null
      }
    ])).toBeNull();
  });

  it("does not mutate any component input", () => {
    const components = [
      {
        code: firstCategory.code,
        label: firstCategory.label,
        exposureScore: 66,
        exposureSourceYear: 2025,
        exposureProvenance: "current-published" as const
      },
      {
        code: secondCategory.code,
        label: secondCategory.label,
        exposureScore: 72,
        exposureSourceYear: 2024,
        exposureProvenance: "historical-published" as const
      }
    ];
    const original = structuredClone(components);

    getMultipleHighExposureAlert(20, components);

    expect(components).toEqual(original);
  });
});
