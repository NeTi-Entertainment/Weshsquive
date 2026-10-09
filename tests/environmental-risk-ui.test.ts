import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import EnvironmentalRiskSection from "../app/environmental-risk-section";
import { getComparativeIndexClassName } from "../src/client/city-search-ui";
import {
  formatEnvironmentalRiskCoverage,
  formatEnvironmentalRiskStatus,
  formatEnvironmentalRiskValue
} from "../src/client/environmental-risk-ui";
import type { EnvironmentalRiskSummary } from "../src/server/environmental-risk";

describe("environmental risk UI formatters", () => {
  it("formats scores with French decimal notation and preserves missing values", () => {
    expect(formatEnvironmentalRiskValue(42.5)).toBe("42,5");
    expect(formatEnvironmentalRiskValue(null)).toBe("Non disponible");
    expect(getComparativeIndexClassName(null)).not.toMatch(/stat-band-/);
  });

  it("formats weighted coverage as a whole French percentage", () => {
    expect(formatEnvironmentalRiskCoverage(0.52)).toBe("52 %");
    expect(formatEnvironmentalRiskCoverage(null)).toBe("Non renseignée");
  });

  it("provides an explicit French label for every environmental status", () => {
    expect(formatEnvironmentalRiskStatus("comparable")).toBe("Indice calculé");
    expect(formatEnvironmentalRiskStatus("insufficient-coverage")).toBe("Couverture insuffisante");
    expect(formatEnvironmentalRiskStatus("no-neighbors")).toBe("Aucune commune dans ce rayon");
    expect(formatEnvironmentalRiskStatus("coordinates-unavailable")).toBe("Coordonnées indisponibles");
  });

  it("renders each radius and keeps unavailable scores uncolored", () => {
    const summaries: EnvironmentalRiskSummary[] = [
      {
        radiusKm: 25,
        value: 42.5,
        status: "comparable",
        scoredNeighborCount: 4,
        totalNeighborCount: 10,
        weightedCoverageRatio: 0.52
      },
      {
        radiusKm: 50,
        value: null,
        status: "insufficient-coverage",
        scoredNeighborCount: 2,
        totalNeighborCount: 5,
        weightedCoverageRatio: 0.4
      },
      {
        radiusKm: 100,
        value: null,
        status: "no-neighbors",
        scoredNeighborCount: 0,
        totalNeighborCount: 0,
        weightedCoverageRatio: null
      },
      {
        radiusKm: 200,
        value: null,
        status: "coordinates-unavailable",
        scoredNeighborCount: 0,
        totalNeighborCount: 0,
        weightedCoverageRatio: null
      }
    ];
    const markup = renderToStaticMarkup(createElement(EnvironmentalRiskSection, { summaries }));

    expect(markup).toContain("Environnement statistique");
    expect(markup.match(/<tr>/g)).toHaveLength(5);
    expect(markup).toContain("25 km");
    expect(markup).toContain("50 km");
    expect(markup).toContain("100 km");
    expect(markup).toContain("200 km");
    expect(markup).toContain("4 / 10");
    expect(markup).toContain("52 %");
    expect(markup).toContain("Non disponible");
    const unavailableScoreRow = markup.split("<th scope=\"row\">50 km</th>")[1]?.split("</tr>")[0] ?? "";
    expect(unavailableScoreRow).toContain("environmental-risk-score");
    expect(unavailableScoreRow).not.toMatch(/stat-band-/);
  });
});
