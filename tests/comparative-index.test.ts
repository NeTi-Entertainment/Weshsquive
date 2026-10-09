import { describe, expect, it } from "vitest";

import { mapComparativeIndex } from "../src/server/comparative-index";

describe("mapComparativeIndex", () => {
  it("exposes category coverage as completeness rather than confidence", () => {
    const result = mapComparativeIndex({
      comparative_index: 72,
      comparative_index_status: "comparable",
      comparative_index_confidence: "high",
      basket_version: "residential-risk-v1",
      published_basket_category_count: 6,
      availability_mask: 63,
      cohort_size: 120,
      population_band: "1000-4999"
    }, 2500);

    expect(result.completeness).toBe("high");
    expect(result).not.toHaveProperty("confidence");
  });
});
