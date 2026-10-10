import { describe, expect, it } from "vitest";

import {
  buildCitySearchUrl,
  collectCategoryColumns,
  comparativeIndexCompletenessLabel,
  comparativeIndexComponentCountLabel,
  comparativeIndexProvenanceLabel,
  comparativeIndexStatusLabel,
  describeComparativeIndex,
  describeBasketAvailability,
  defaultSearchForm,
  findCategory,
  formatCategoryRate,
  formatComparisonCoverage,
  formatInteger,
  formatPopulation,
  formatRate,
  getPercentileBand,
  getNextOffset,
  getPreviousOffset,
  getSortStateForColumn,
  getStatCellClassName,
  updateSortForColumn,
  type CitySearchResult
} from "../src/client/city-search-ui";

describe("comparativeIndexCompletenessLabel", () => {
  it("describes basket completeness without claiming statistical confidence", () => {
    expect(comparativeIndexCompletenessLabel("high")).toBe("Complétude de l’indice : élevée");
    expect(comparativeIndexCompletenessLabel("medium")).toBe("Complétude de l’indice : moyenne");
    expect(comparativeIndexCompletenessLabel("low")).toBe("Complétude de l’indice : faible");
  });
});

describe("comparative index provenance presentation", () => {
  it("uses the four approved French provenance labels", () => {
    expect([
      comparativeIndexProvenanceLabel("published-only"),
      comparativeIndexProvenanceLabel("partially-estimated"),
      comparativeIndexProvenanceLabel("estimated-only"),
      comparativeIndexProvenanceLabel("unavailable")
    ]).toEqual([
      "Données communales publiées",
      "Partiellement estimé",
      "Entièrement estimé",
      "Indice indisponible"
    ]);
  });

  it("qualifies the score with component counts, population band and published reference size", () => {
    expect(describeComparativeIndex({
      value: 60,
      status: "comparable",
      provenance: "partially-estimated",
      completeness: "high",
      basketVersion: "residential-risk-v2",
      publishedComponentCount: 3,
      estimatedComponentCount: 3,
      comparableComponentCount: 6,
      minimumReferenceCohortSize: 50,
      basketCategoryCount: 6,
      basketAvailability: [],
      populationBand: "1000-4999"
    })).toBe(
      "Partiellement estimé · Composantes disponibles dans le panier : 3 publiées, 3 estimées · composantes effectivement comparées dans l’indice : 6 · tranche 1 000 à 4 999 habitants · cohorte publiée minimale : 50 communes. Les valeurs estimées sont des moyennes départementales SSMSI des communes masquées, pas des statistiques communales publiées."
    );
  });

  it("does not imply available components were all comparable", () => {
    expect(comparativeIndexComponentCountLabel({
      value: null,
      status: "population-unavailable",
      provenance: "unavailable",
      completeness: null,
      basketVersion: "residential-risk-v2",
      publishedComponentCount: 6,
      estimatedComponentCount: 0,
      comparableComponentCount: 0,
      minimumReferenceCohortSize: 0,
      basketCategoryCount: 6,
      basketAvailability: [],
      populationBand: null
    })).toBe("Composantes disponibles dans le panier : 6 publiées, 0 estimées · composantes effectivement comparées dans l’indice : 0");
  });
});

describe("comparativeIndexStatusLabel", () => {
  it("keeps the transitional cohort status readable while exposing the v2 status", () => {
    expect(comparativeIndexStatusLabel("reference-cohort-too-small")).toBe("Groupe trop petit");
  });
});

describe("describeBasketAvailability", () => {
  it("distinguishes published, estimated and unavailable basket components", () => {
    expect(describeBasketAvailability([
      { code: "published", label: "Publié", available: true, estimated: false },
      { code: "estimated", label: "Estimé", available: true, estimated: true },
      { code: "missing", label: "Absent", available: false, estimated: false }
    ])).toBe("Publiées : Publié. Estimées : Estimé. Indisponibles : Absent.");
  });
});

describe("buildCitySearchUrl", () => {
  it("serializes filled filters", () => {
    const url = buildCitySearchUrl({
      ...defaultSearchForm,
      year: "2025",
      regionCode: "11",
      commune: " Seugy ",
      populationMin: "1000",
      categoryCode: "ssmsi-cambriolages",
      categoryIncidentMin: "2",
      sortBy: "categoryRatePer1000",
      sortDirection: "desc",
      sortCategoryCode: "ssmsi-cambriolages",
      limit: "50",
      offset: "0"
    });

    expect(url).toBe(
      "/api/cities/search?year=2025&regionCode=11&commune=Seugy&populationMin=1000&categoryCode=ssmsi-cambriolages&categoryIncidentMin=2&sortBy=categoryRatePer1000&sortDirection=desc&sortCategoryCode=ssmsi-cambriolages&limit=50&offset=0"
    );
  });

  it("never serializes a removed global-rate filter", () => {
    const state = { ...defaultSearchForm, year: "2025" } as typeof defaultSearchForm & {
      partialRateMin?: string;
    };
    state.partialRateMin = "0";

    expect(buildCitySearchUrl(state)).not.toContain("partialRate");
  });
});

describe("collectCategoryColumns", () => {
  const rows: CitySearchResult[] = [
    {
      inseeCode: "95584",
      name: "Seugy",
      departmentCode: "95",
      departmentName: "Val-d'Oise",
      regionCode: "11",
      regionName: "Ile-de-France",
      population: 1044,
      populationYear: 2023,
      published: {
        publishedCategoryCount: 2,
        totalCategoryCount: 15,
        coverageRatio: "0.1333"
      },
      comparativeIndex: {
        value: 80,
        status: "comparable",
        provenance: "partially-estimated",
        completeness: "high",
        basketVersion: "residential-risk-v2",
        publishedComponentCount: 3,
        estimatedComponentCount: 1,
        comparableComponentCount: 6,
        minimumReferenceCohortSize: 42,
        basketCategoryCount: 4,
        basketAvailability: [
          { code: "cambriolages", label: "Cambriolages", available: true, estimated: false }
        ],
        populationBand: "1000-2499"
      },
      categories: [
        {
          code: "violences",
          label: "Violences sexuelles",
          incidentCount: null,
          ratePer1000: null,
          countUnit: "Victime",
          rateDenominator: "population",
          populationDenominator: 1044,
          populationDenominatorYear: 2023,
          housingDenominator: 500,
          housingDenominatorYear: 2023,
          publicationStatus: "masked"
        },
        {
          code: "cambriolages",
          label: "Cambriolages de logement",
          incidentCount: 4,
          ratePer1000: "3.83",
          countUnit: "Infraction",
          rateDenominator: "housing",
          populationDenominator: 1044,
          populationDenominatorYear: 2023,
          housingDenominator: 500,
          housingDenominatorYear: 2023,
          publicationStatus: "published"
        }
      ]
    },
    {
      inseeCode: "95000",
      name: "Autre commune",
      departmentCode: "95",
      departmentName: "Val-d'Oise",
      regionCode: "11",
      regionName: "Ile-de-France",
      population: 2000,
      populationYear: 2023,
      published: {
        publishedCategoryCount: 1,
        totalCategoryCount: 15,
        coverageRatio: "0.0667"
      },
      comparativeIndex: {
        value: null,
        status: "insufficient-coverage",
        provenance: "unavailable",
        completeness: null,
        basketVersion: "residential-risk-v2",
        publishedComponentCount: 0,
        estimatedComponentCount: 0,
        comparableComponentCount: 0,
        minimumReferenceCohortSize: 0,
        basketCategoryCount: 4,
        basketAvailability: [],
        populationBand: null
      },
      categories: [
        {
          code: "cambriolages",
          label: "Cambriolages de logement",
          incidentCount: 3,
          ratePer1000: "1.5",
          countUnit: "Infraction",
          rateDenominator: "housing",
          populationDenominator: 2000,
          populationDenominatorYear: 2023,
          housingDenominator: 2000,
          housingDenominatorYear: 2023,
          publicationStatus: "published"
        }
      ]
    }
  ];

  it("deduplicates and alphabetizes category columns", () => {
    expect(collectCategoryColumns(rows).map((category) => category.code)).toEqual([
      "cambriolages",
      "violences"
    ]);
  });

  it("finds a row category by code", () => {
    expect(findCategory(rows[0], "cambriolages")?.incidentCount).toBe(4);
  });
});

describe("formatting and paging", () => {
  it("formats French integers and rates", () => {
    expect(formatInteger(1234567)).toBe("1 234 567");
    expect(formatInteger(null)).toBe("Non publié");
    expect(formatPopulation(1234567)).toBe("1 234 567");
    expect(formatPopulation(null)).toBe("Non renseignée");
    expect(formatRate("3.8314")).toBe("3,83 ‰");
    expect(formatRate(null)).toBe("Non publié");
  });

  it("labels rates with the official denominator and its vintage", () => {
    expect(formatCategoryRate("3.83", "housing", 2023, 2022)).toBe(
      "3,83 ‰ · pour 1 000 logements (Insee 2022)"
    );
    expect(formatCategoryRate("1.5", "population", 2023, null)).toBe(
      "1,5 ‰ · pour 1 000 habitants (Insee 2023)"
    );
    expect(formatCategoryRate("1.5", "unknown", 2023, 2022)).toBe(
      "1,5 ‰ · base inconnue"
    );
    expect(formatCategoryRate(null, "housing", 2023, 2022)).toBe(
      "Non publié · pour 1 000 logements (Insee 2022)"
    );
    expect(formatComparisonCoverage(2, 4)).toBe("2 / 4 communes (50 %)");
    expect(formatComparisonCoverage(0, 0)).toBe("Aucune commune avec cet indicateur");
  });

  it("computes paging offsets", () => {
    const state = { ...defaultSearchForm, offset: "100" };

    expect(getNextOffset(state)).toBe("150");
    expect(getPreviousOffset(state)).toBe("50");
  });
});

describe("sorting helpers", () => {
  const baseState = { ...defaultSearchForm, offset: "100" };

  it("starts sorting a metric in descending order and resets pagination", () => {
    expect(updateSortForColumn(baseState, "comparativeIndex")).toEqual({
      ...baseState,
      sortBy: "comparativeIndex",
      sortDirection: "desc",
      sortCategoryCode: "",
      offset: "0"
    });
  });

  it("toggles the same metric between descending and ascending order", () => {
    expect(
      updateSortForColumn(
        {
          ...baseState,
          sortBy: "comparativeIndex",
          sortDirection: "desc"
        },
        "comparativeIndex"
      ).sortDirection
    ).toBe("asc");
  });

  it("tracks category sorting separately by code", () => {
    const sorted = updateSortForColumn(baseState, "categoryIncidentCount", "cambriolages");

    expect(sorted).toMatchObject({
      sortBy: "categoryIncidentCount",
      sortDirection: "desc",
      sortCategoryCode: "cambriolages",
      offset: "0"
    });
    expect(getSortStateForColumn(sorted, "categoryIncidentCount", "cambriolages")).toEqual({
      isActive: true,
      direction: "desc"
    });
    expect(getSortStateForColumn(sorted, "categoryIncidentCount", "violences")).toEqual({
      isActive: false,
      direction: ""
    });
  });
});

describe("percentile color helpers", () => {
  it("maps statistical percentiles to the planned six color bands", () => {
    expect(getPercentileBand(null)).toBe("");
    expect(getPercentileBand("0.10")).toBe("very-low");
    expect(getPercentileBand(0.35)).toBe("low");
    expect(getPercentileBand("0.50")).toBe("medium");
    expect(getPercentileBand("0.75")).toBe("high");
    expect(getPercentileBand("0.90")).toBe("very-high");
    expect(getPercentileBand("0.98")).toBe("extreme");
  });

  it("builds a stable cell class only when a percentile exists", () => {
    expect(getStatCellClassName("0.98")).toBe("stat-cell stat-band-extreme");
    expect(getStatCellClassName(null)).toBe("");
    expect(getStatCellClassName("0.98", "muted-cell")).toBe(
      "muted-cell stat-cell stat-band-extreme"
    );
  });
});
