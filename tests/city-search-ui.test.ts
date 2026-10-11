import { describe, expect, it } from "vitest";

import {
  buildCitySearchUrl,
  collectCategoryColumns,
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
  getComparativeIndexClassName,
  getNextOffset,
  getPreviousOffset,
  getSortStateForColumn,
  getStatCellClassName,
  updateSortForColumn,
  type CitySearchResult
} from "../src/client/city-search-ui";
import { exposureComponentSourceLabel } from "../src/server/comparative-index";

describe("comparative index provenance presentation", () => {
  it("uses the four approved French provenance labels", () => {
    expect([
      comparativeIndexProvenanceLabel("published-only"),
      comparativeIndexProvenanceLabel("historical-published"),
      comparativeIndexProvenanceLabel("partially-estimated"),
      comparativeIndexProvenanceLabel("estimated-only"),
      comparativeIndexProvenanceLabel("unavailable")
    ]).toEqual([
      "Données communales publiées",
      "Données communales complétées par l’historique",
      "Partiellement estimé",
      "Entièrement estimé",
      "Indisponible"
    ]);
  });

  it("identifies the exact year and source of each exposure component", () => {
    expect(exposureComponentSourceLabel("current-published", 2025, 2025))
      .toBe("Donnée communale publiée en 2025");
    expect(exposureComponentSourceLabel("historical-published", 2024, 2025))
      .toBe("Donnée communale historique publiée en 2024");
    expect(exposureComponentSourceLabel("department-masked-average", 2025, 2025))
      .toBe("Estimation issue du complément départemental 2025");
  });

  it("qualifies the score with basket coverage and estimation provenance, not a population cohort", () => {
    expect(describeComparativeIndex({
      value: 60,
      status: "available",
      provenance: "partially-estimated",
      basketVersion: "absolute-exposure-v2",
      publishedComponentCount: 3,
      historicalPublishedComponentCount: 0,
      estimatedComponentCount: 3,
      availableComponentCount: 6,
      coverageRatio: 1,
      oldestSourceYear: 2025,
      lowVolumeCapApplied: true,
      basketCategoryCount: 6,
      basketAvailability: []
    })).toBe(
      "Partiellement estimé · Couverture du panier : 6/6 composantes exploitables (3 publiées pour l’année cible, 0 historiques, 3 estimées) Les valeurs estimées sont des moyennes départementales SSMSI des communes masquées, pas des statistiques communales publiées. Le score a été plafonné à 35 selon la règle de faible volume publiée."
    );
  });

  it("describes the number of usable components as basket coverage", () => {
    expect(comparativeIndexComponentCountLabel({
      value: null,
      status: "unavailable",
      provenance: "unavailable",
      basketVersion: "absolute-exposure-v2",
      publishedComponentCount: 6,
      historicalPublishedComponentCount: 0,
      estimatedComponentCount: 0,
      availableComponentCount: 0,
      coverageRatio: 0,
      oldestSourceYear: null,
      lowVolumeCapApplied: false,
      basketCategoryCount: 6,
      basketAvailability: []
    })).toBe("Couverture du panier : 0/6 composantes exploitables (6 publiées pour l’année cible, 0 historiques, 0 estimées)");
  });
});

describe("comparativeIndexStatusLabel", () => {
  it("uses neutral statuses that no longer imply relative comparability", () => {
    expect(comparativeIndexStatusLabel("available")).toBe("Score disponible");
    expect(comparativeIndexStatusLabel("unavailable")).toBe("Aucune composante exploitable");
  });
});

describe("describeBasketAvailability", () => {
  it("distinguishes current, historical, estimated and unavailable components", () => {
    expect(describeBasketAvailability([
      { code: "published", label: "Publié", available: true, estimated: false, historical: false },
      { code: "historical", label: "Historique", available: true, estimated: false, historical: true },
      { code: "estimated", label: "Estimé", available: true, estimated: true, historical: false },
      { code: "missing", label: "Absent", available: false, estimated: false, historical: false }
    ])).toBe("Publiées pour l’année cible : Publié. Historiques : Historique. Estimées : Estimé. Indisponibles : Absent.");
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
        status: "available",
        provenance: "partially-estimated",
        basketVersion: "absolute-exposure-v2",
        publishedComponentCount: 3,
        historicalPublishedComponentCount: 0,
        estimatedComponentCount: 1,
        availableComponentCount: 4,
        coverageRatio: 4 / 6,
        oldestSourceYear: 2025,
        lowVolumeCapApplied: false,
        basketCategoryCount: 4,
        basketAvailability: [
      { code: "cambriolages", label: "Cambriolages", available: true, estimated: false, historical: false }
        ]
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
          publicationStatus: "masked",
          exposureSourceYear: 2024,
          exposureProvenance: "historical-published",
          exposureRatePer1000: 2.4,
          exposureScore: 15
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
          publicationStatus: "published",
          exposureSourceYear: 2025,
          exposureProvenance: "current-published",
          exposureRatePer1000: 3.83,
          exposureScore: 23.9
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
        status: "unavailable",
        provenance: "unavailable",
        basketVersion: "absolute-exposure-v2",
        publishedComponentCount: 0,
        historicalPublishedComponentCount: 0,
        estimatedComponentCount: 0,
        availableComponentCount: 0,
        coverageRatio: 0,
        oldestSourceYear: null,
        lowVolumeCapApplied: false,
        basketCategoryCount: 4,
        basketAvailability: []
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
          publicationStatus: "published",
          exposureSourceYear: null,
          exposureProvenance: null,
          exposureRatePer1000: null,
          exposureScore: null
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

  it("colors the exposure score on the absolute application scale", () => {
    expect(getComparativeIndexClassName(0)).toBe("stat-cell stat-band-very-low");
    expect(getComparativeIndexClassName(10)).toBe("stat-cell stat-band-very-low");
    expect(getComparativeIndexClassName(35.1)).toBe("stat-cell stat-band-medium");
    expect(getComparativeIndexClassName(65.1)).toBe("stat-cell stat-band-very-high");
    expect(getComparativeIndexClassName(null)).toBe("");
  });
});
