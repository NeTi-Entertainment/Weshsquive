import { Pool } from "pg";
import { describe, expect, it } from "vitest";

import {
  buildCityComparisonQuery,
  buildCityDetailQuery,
  buildCityHistoryQuery
} from "../src/server/city-detail";
import { buildCitySearchQuery } from "../src/server/city-search";
import {
  buildNearbyCitySearchQuery,
  parseNearbyCitySearchParams
} from "../src/server/nearby-city-search";

const explainEnabled = process.env.SEARCH_METRICS_EXPLAIN === "1";

describe.skipIf(!explainEnabled)("search query plans", () => {
  it("prints analyzed plans for search, nearby, and city detail reads", async () => {
    const pool = new Pool({
      connectionString: process.env.DATABASE_URL ??
        "postgres://app:app_dev_password@localhost:5432/app_criminalite"
    });

    const explain = async (
      label: string,
      query: { text: string; values: Array<string | number> }
    ) => {
      const result = await pool.query<{ "QUERY PLAN": string }>(
        `explain (analyze, buffers, format text) ${query.text}`,
        query.values
      );
      const plan = result.rows.map((row) => row["QUERY PLAN"]).join("\n");
      const summary = plan.split(/\r?\n/).filter((line) =>
        /(?:Planning|Execution) Time:|Buffers:.*temp|Scan (?:on|using) search_metrics_/.test(line)
      );
      console.log(`\n--- ${label} ---\n${summary.join("\n")}`);
      expect(plan).toContain("Execution Time:");
      return result;
    };

    try {
      const categoryCode = "ssmsi-78384436563146dc6167ea53b7b5e0cd";
      await explain("main combined search", buildCitySearchQuery({
        year: 2025,
        regionCode: "11",
        departmentCode: "95",
        populationMin: 1000,
        populationMax: 50000,
        categoryCode,
        categoryIncidentMin: 1,
        limit: 50,
        offset: 0
      }));

      await explain("nearby search 25 km", buildNearbyCitySearchQuery(
        parseNearbyCitySearchParams("95594", new URLSearchParams({
          year: "2025",
          radiusKm: "25",
          limit: "200",
          offset: "0"
        }))
      ));

      const detailQuery = buildCityDetailQuery({ inseeCode: "95584", year: 2025 });
      const detailResult = await pool.query<{ snapshot_id: string }>(detailQuery.text, detailQuery.values);
      const snapshotId = String(detailResult.rows[0]?.snapshot_id ?? "");
      expect(snapshotId).not.toBe("");
      await explain("city detail", detailQuery);

      await explain("city history", buildCityHistoryQuery("95584", snapshotId));
      const comparisonQuery = buildCityComparisonQuery(
        { inseeCode: "95584", year: 2025 },
        snapshotId
      );
      await explain("territorial comparisons", comparisonQuery);

      const pujaudranComparisons = buildCityComparisonQuery(
        { inseeCode: "32334", year: 2025 },
        snapshotId
      );
      const comparisonResult = await pool.query<{
        category_label: string;
        scope: string;
        rate_per_1000: string | null;
        published_city_count: number;
        total_city_count: number;
      }>(pujaudranComparisons.text, pujaudranComparisons.values);
      const burglaryScopes = comparisonResult.rows.filter(
        (row) => row.category_label === "Cambriolages de logement"
      );

      expect(burglaryScopes.find((row) => row.scope === "commune")).toMatchObject({
        rate_per_1000: "8.2581",
        published_city_count: 1,
        total_city_count: 1
      });
      expect(burglaryScopes.find((row) => row.scope === "france")).toMatchObject({
        published_city_count: 10474,
        total_city_count: 34875
      });
    } finally {
      await pool.end();
    }
  }, 180_000);
});
