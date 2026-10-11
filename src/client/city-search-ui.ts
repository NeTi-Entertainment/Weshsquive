import {
  comparativeIndexProvenanceLabel,
  exposureComponentSourceLabel,
  type ComparativeIndex,
  type ComparativeIndexStatus
} from "@/server/comparative-index";
import { getExposureRiskBand } from "@/shared/exposure-index";

export { comparativeIndexProvenanceLabel, exposureComponentSourceLabel };

export type CitySearchFormState = {
  year: string;
  regionCode: string;
  departmentCode: string;
  commune: string;
  populationMin: string;
  populationMax: string;
  comparativeIndexMin: string;
  comparativeIndexMax: string;
  categoryCode: string;
  categoryIncidentMin: string;
  categoryIncidentMax: string;
  categoryRateMin: string;
  categoryRateMax: string;
  sortBy: string;
  sortDirection: string;
  sortCategoryCode: string;
  limit: string;
  offset: string;
};

export type CitySearchSortBy =
  | "name"
  | "population"
  | "comparativeIndex"
  | "categoryIncidentCount"
  | "categoryRatePer1000";

export type CitySearchSortDirection = "asc" | "desc";

export type CitySearchCategory = {
  code: string;
  label: string;
  incidentCount: number | null;
  ratePer1000: string | number | null;
  countUnit: string | null;
  rateDenominator: "population" | "housing" | "unknown";
  populationDenominator: number | null;
  populationDenominatorYear: number | null;
  housingDenominator: number | null;
  housingDenominatorYear: number | null;
  publicationStatus: "published" | "masked" | "unknown";
  exposureSourceYear: number | null;
  exposureProvenance: "current-published" | "historical-published" | "department-masked-average" | "unavailable" | null;
  exposureRatePer1000: number | null;
  exposureScore: number | null;
};

export type CitySearchResult = {
  inseeCode: string;
  name: string;
  departmentCode: string;
  departmentName: string;
  regionCode: string;
  regionName: string;
  population: number | null;
  populationYear: number | null;
  published: {
    publishedCategoryCount: number;
    totalCategoryCount: number;
    coverageRatio: string | number | null;
  };
  comparativeIndex: ComparativeIndex;
  categories: CitySearchCategory[];
};

export const defaultSearchForm: CitySearchFormState = {
  year: "2025",
  regionCode: "",
  departmentCode: "",
  commune: "",
  populationMin: "",
  populationMax: "",
  comparativeIndexMin: "",
  comparativeIndexMax: "",
  categoryCode: "",
  categoryIncidentMin: "",
  categoryIncidentMax: "",
  categoryRateMin: "",
  categoryRateMax: "",
  sortBy: "",
  sortDirection: "",
  sortCategoryCode: "",
  limit: "50",
  offset: "0"
};

const queryKeys: Array<keyof CitySearchFormState> = [
  "year",
  "regionCode",
  "departmentCode",
  "commune",
  "populationMin",
  "populationMax",
  "comparativeIndexMin",
  "comparativeIndexMax",
  "categoryCode",
  "categoryIncidentMin",
  "categoryIncidentMax",
  "categoryRateMin",
  "categoryRateMax",
  "sortBy",
  "sortDirection",
  "sortCategoryCode",
  "limit",
  "offset"
];

export function buildCitySearchUrl(state: CitySearchFormState): string {
  const params = new URLSearchParams();
  const hasSelectedCategory = state.categoryCode.trim() !== "";

  for (const key of queryKeys) {
    if (
      !hasSelectedCategory &&
      (key === "categoryIncidentMin" ||
        key === "categoryIncidentMax" ||
        key === "categoryRateMin" ||
        key === "categoryRateMax")
    ) {
      continue;
    }

    const value = state[key].trim();
    if (value !== "") {
      params.set(key, value);
    }
  }

  return `/api/cities/search?${params.toString()}`;
}
export function collectCategoryColumns(results: CitySearchResult[]): CitySearchCategory[] {
  const byCode = new Map<string, CitySearchCategory>();

  for (const result of results) {
    for (const category of result.categories) {
      if (!byCode.has(category.code)) {
        byCode.set(category.code, category);
      }
    }
  }

  return Array.from(byCode.values()).sort((left, right) =>
    left.label.localeCompare(right.label, "fr")
  );
}

export function findCategory(
  result: CitySearchResult,
  categoryCode: string
): CitySearchCategory | undefined {
  return result.categories.find((category) => category.code === categoryCode);
}

export function formatInteger(value: number | null): string {
  if (value === null) {
    return "Non publié";
  }

  return new Intl.NumberFormat("fr-FR").format(value);
}

export function formatPopulation(value: number | null): string {
  return value === null ? "Non renseignée" : new Intl.NumberFormat("fr-FR").format(value);
}

export function formatRate(value: string | number | null): string {
  if (value === null) {
    return "Non publié";
  }

  return `${new Intl.NumberFormat("fr-FR", {
    maximumFractionDigits: 2
  }).format(Number(value))} ‰`;
}

export function formatCategoryRate(
  value: string | number | null,
  denominator: CitySearchCategory["rateDenominator"],
  populationYear: number | null,
  housingYear: number | null
): string {
  const formattedRate = formatRate(value);
  if (denominator === "unknown") {
    return `${formattedRate} · base inconnue`;
  }

  const noun = denominator === "housing" ? "logements" : "habitants";
  const vintage = denominator === "housing" ? housingYear : populationYear;
  const vintageLabel = vintage === null ? "millésime inconnu" : `Insee ${vintage}`;
  return `${formattedRate} · pour 1 000 ${noun} (${vintageLabel})`;
}

export function getNextOffset(state: CitySearchFormState): string {
  const limit = Number(state.limit || defaultSearchForm.limit);
  const offset = Number(state.offset || defaultSearchForm.offset);

  return String(offset + limit);
}

export function getPreviousOffset(state: CitySearchFormState): string {
  const limit = Number(state.limit || defaultSearchForm.limit);
  const offset = Number(state.offset || defaultSearchForm.offset);

  return String(Math.max(0, offset - limit));
}

export function updateSortForColumn(
  state: CitySearchFormState,
  sortBy: CitySearchSortBy,
  sortCategoryCode = ""
): CitySearchFormState {
  const isSameColumn =
    state.sortBy === sortBy &&
    (sortBy !== "categoryIncidentCount" && sortBy !== "categoryRatePer1000"
      ? true
      : state.sortCategoryCode === sortCategoryCode);
  const nextDirection: CitySearchSortDirection =
    isSameColumn && state.sortDirection === "desc" ? "asc" : "desc";

  return {
    ...state,
    sortBy,
    sortDirection: nextDirection,
    sortCategoryCode:
      sortBy === "categoryIncidentCount" || sortBy === "categoryRatePer1000"
        ? sortCategoryCode
        : "",
    offset: "0"
  };
}

export function getSortStateForColumn(
  state: CitySearchFormState,
  sortBy: CitySearchSortBy,
  sortCategoryCode = ""
): { isActive: boolean; direction: CitySearchSortDirection | "" } {
  const isActive =
    state.sortBy === sortBy &&
    (sortBy !== "categoryIncidentCount" && sortBy !== "categoryRatePer1000"
      ? true
      : state.sortCategoryCode === sortCategoryCode);

  return {
    isActive,
    direction: isActive && (state.sortDirection === "asc" || state.sortDirection === "desc")
      ? state.sortDirection
      : ""
  };
}

export function getPercentileBand(value: string | number | null): string {
  if (value === null) {
    return "";
  }

  const percentile = Number(value);

  if (!Number.isFinite(percentile)) {
    return "";
  }

  if (percentile <= 0.2) {
    return "very-low";
  }

  if (percentile <= 0.4) {
    return "low";
  }

  if (percentile <= 0.6) {
    return "medium";
  }

  if (percentile <= 0.8) {
    return "high";
  }

  if (percentile <= 0.95) {
    return "very-high";
  }

  return "extreme";
}

export function getStatCellClassName(
  percentile: string | number | null,
  baseClassName = ""
): string {
  const band = getPercentileBand(percentile);

  if (band === "") {
    return baseClassName;
  }

  return [baseClassName, "stat-cell", `stat-band-${band}`].filter(Boolean).join(" ");
}

export function getComparativeIndexClassName(value: number | null): string {
  const band = getExposureRiskBand(value);
  return band === "" ? "" : ["stat-cell", `stat-band-${band}`].join(" ");
}

export function formatComparativeIndex(value: number | null): string {
  return value === null
    ? "Non disponible"
    : `${new Intl.NumberFormat("fr-FR", { maximumFractionDigits: 1 }).format(value)} / 100`;
}

export function describeComparativeIndex(index: ComparativeIndex): string {
  const provenance = comparativeIndexProvenanceLabel(index.provenance);
  const componentCounts = comparativeIndexComponentCountLabel(index);
  const estimationNote = index.estimatedComponentCount > 0
    ? " Les valeurs estimées sont des moyennes départementales SSMSI des communes masquées, pas des statistiques communales publiées."
    : "";
  const capNote = index.lowVolumeCapApplied
    ? " Le score a été plafonné à 35 selon la règle de faible volume publiée."
    : "";
  const historyNote = index.historicalPublishedComponentCount > 0
    ? " Les taux communaux publiés jusqu’à trois ans avant le millésime cible sont privilégiés sur les compléments départementaux."
    : "";

  return `${provenance} · ${componentCounts}${historyNote}${estimationNote}${capNote}`;
}

export function comparativeIndexComponentCountLabel(index: ComparativeIndex): string {
  return `Couverture du panier : ${index.availableComponentCount}/${index.basketCategoryCount} composantes exploitables (${index.publishedComponentCount} publiées pour l’année cible, ${index.historicalPublishedComponentCount} historiques, ${index.estimatedComponentCount} estimées)`;
}

export function formatCoverage(published: number, total: number): string {
  if (total === 0) {
    return "Aucune donnée annuelle";
  }

  return `${published} / ${total} catégories (${new Intl.NumberFormat("fr-FR", {
    style: "percent",
    maximumFractionDigits: 0
  }).format(published / total)})`;
}

export function formatComparisonCoverage(published: number, total: number): string {
  if (total === 0) {
    return "Aucune commune avec cet indicateur";
  }

  return `${formatInteger(published)} / ${formatInteger(total)} communes (${new Intl.NumberFormat("fr-FR", {
    style: "percent",
    maximumFractionDigits: 0
  }).format(published / total)})`;
}

export function describeBasketAvailability(
  availability: ComparativeIndex["basketAvailability"]
): string {
  const published = availability.filter((category) => category.available && !category.historical && !category.estimated);
  const historical = availability.filter((category) => category.available && category.historical);
  const estimated = availability.filter((category) => category.available && category.estimated);
  const unavailable = availability.filter((category) => !category.available);
  const labels = (categories: typeof availability) =>
    categories.length > 0 ? categories.map((category) => category.label).join(", ") : "aucune";

  return `Publiées pour l’année cible : ${labels(published)}. Historiques : ${labels(historical)}. Estimées : ${labels(estimated)}. Indisponibles : ${labels(unavailable)}.`;
}

export function comparativeIndexStatusLabel(
  status: ComparativeIndexStatus
): string {
  switch (status) {
    case "available":
      return "Score disponible";
    default:
      return "Aucune composante exploitable";
  }
}
