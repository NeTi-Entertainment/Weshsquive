import { describe, expect, it } from "vitest";

import {
  ENVIRONMENTAL_RADII_KM,
  buildCityEnvironmentalRiskQuery,
  buildMapEnvironmentalRiskQuery,
  summarizeEnvironmentalRisk,
  type EnvironmentalNeighborRow
} from "../src/server/environmental-risk";

function neighbor(
  neighborInseeCode: string,
  distanceKm: number,
  comparativeIndex: number | null,
  targetInseeCode = "95584"
): EnvironmentalNeighborRow {
  return { targetInseeCode, neighborInseeCode, distanceKm, comparativeIndex };
}

describe("environmental risk summaries", () => {
  it("uses the linear distance weights for a comparable score", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 20),
      neighbor("01002", 12.5, 80),
      neighbor("01003", 10, 40)
    ]);

    expect(summary).toEqual({
      radiusKm: 25,
      value: 40,
      status: "comparable",
      scoredNeighborCount: 3,
      totalNeighborCount: 3,
      weightedCoverageRatio: 1
    });
  });

  it("excludes the target commune from its own neighborhood", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("95584", 0, 100),
      neighbor("01001", 0, 20),
      neighbor("01002", 0, 20),
      neighbor("01003", 0, 20)
    ]);

    expect(summary.value).toBe(20);
    expect(summary.scoredNeighborCount).toBe(3);
    expect(summary.totalNeighborCount).toBe(3);
  });

  it("keeps neighbors without an index in the weighted coverage denominator", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 40),
      neighbor("01002", 0, 40),
      neighbor("01003", 0, 40),
      neighbor("01004", 0, null)
    ]);

    expect(summary.value).toBe(40);
    expect(summary.scoredNeighborCount).toBe(3);
    expect(summary.totalNeighborCount).toBe(4);
    expect(summary.weightedCoverageRatio).toBe(0.75);
  });

  it("does not expose a value with fewer than three scored neighbors", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 20),
      neighbor("01002", 12.5, 80)
    ]);

    expect(summary.value).toBeNull();
    expect(summary.status).toBe("insufficient-coverage");
    expect(summary.scoredNeighborCount).toBe(2);
  });

  it("accepts exactly 50 percent weighted coverage", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 20),
      neighbor("01002", 0, 40),
      neighbor("01003", 0, 60),
      neighbor("01004", 12.5, null),
      neighbor("01005", 12.5, null),
      neighbor("01006", 12.5, null),
      neighbor("01007", 12.5, null),
      neighbor("01008", 12.5, null),
      neighbor("01009", 12.5, null)
    ]);

    expect(summary.value).toBe(40);
    expect(summary.status).toBe("comparable");
    expect(summary.scoredNeighborCount).toBe(3);
    expect(summary.totalNeighborCount).toBe(9);
    expect(summary.weightedCoverageRatio).toBe(0.5);
  });

  it("rejects exactly 50 percent row coverage when weighted coverage is below 50 percent", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 20, 20),
      neighbor("01002", 20, 40),
      neighbor("01003", 20, 60),
      neighbor("01004", 0, null),
      neighbor("01005", 0, null),
      neighbor("01006", 0, null)
    ]);

    expect(summary.value).toBeNull();
    expect(summary.status).toBe("insufficient-coverage");
    expect(summary.scoredNeighborCount).toBe(3);
    expect(summary.totalNeighborCount).toBe(6);
    expect(summary.weightedCoverageRatio).toBeLessThan(0.5);
  });

  it("reports insufficient coverage below 50 percent", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 20),
      neighbor("01002", 0, 40),
      neighbor("01003", 0, 60),
      neighbor("01004", 0, null),
      neighbor("01005", 0, null),
      neighbor("01006", 0, null),
      neighbor("01007", 0, null)
    ]);

    expect(summary.value).toBeNull();
    expect(summary.status).toBe("insufficient-coverage");
    expect(summary.weightedCoverageRatio).toBeLessThan(0.5);
  });

  it("uses a weight of one at zero distance", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 20),
      neighbor("01002", 12.5, 80),
      neighbor("01003", 10, 40)
    ]);

    expect(summary.value).toBe(40);
  });

  it("excludes neighbors exactly on the radius boundary", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, [
      neighbor("01001", 0, 50),
      neighbor("01002", 10, 50),
      neighbor("01003", 20, 50),
      neighbor("01004", 25, null)
    ]);

    expect(summary.totalNeighborCount).toBe(3);
    expect(summary.weightedCoverageRatio).toBe(1);
  });

  it("reports unavailable coordinates without manufacturing a score", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, false, []);

    expect(summary).toEqual({
      radiusKm: 25,
      value: null,
      status: "coordinates-unavailable",
      scoredNeighborCount: 0,
      totalNeighborCount: 0,
      weightedCoverageRatio: null
    });
  });

  it("reports a geolocated target with no neighbors separately", () => {
    const summary = summarizeEnvironmentalRisk("95584", 25, true, []);

    expect(summary.status).toBe("no-neighbors");
    expect(summary.value).toBeNull();
    expect(summary.weightedCoverageRatio).toBeNull();
  });
});

describe("environmental risk queries", () => {
  it("defines the four supported radii", () => {
    expect(ENVIRONMENTAL_RADII_KM).toEqual([25, 50, 100, 200]);
  });

  it("queries one city's neighbors with its requested year and snapshot", () => {
    const query = buildCityEnvironmentalRiskQuery("95584", 2025, "42");

    expect(query.values).toEqual(["95584", 2025, "42"]);
    expect(query.text).toContain("st_dwithin");
    expect(query.text).toContain("200");
    expect(query.text).toContain("c.insee_code <> target.insee_code");
    expect(query.text).toContain("metrics.year = $2");
    expect(query.text).toContain("metrics.snapshot_id = $3");
    expect(query.text).toContain("left join search_metrics_city_year_comparative");
    expect(query.text).toMatch(/st_distance[\s\S]*<|<[^\n]*st_distance/i);
  });

  it("queries map targets in a batch and retains neighbors with missing indices", () => {
    const query = buildMapEnvironmentalRiskQuery(["95584", "95313"], 2025, "42", 50);

    expect(query.values).toEqual([["95584", "95313"], 2025, "42", 50000]);
    expect(query.text).toContain("unnest($1::varchar[])");
    expect(query.text).toContain("metrics.year = $2");
    expect(query.text).toContain("metrics.snapshot_id = $3");
    expect(query.text).toContain("st_dwithin");
    expect(query.text).toContain("c.insee_code <> targets.insee_code");
    expect(query.text).toContain("left join search_metrics_city_year_comparative");
    expect(query.text).toContain("< $4");
  });
});
