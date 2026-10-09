import type { NearbyMapCriterion } from "@/client/nearby-map-ui";
import {
  ENVIRONMENTAL_RADII_KM,
  type EnvironmentalRadiusKm
} from "@/server/environmental-risk";

export type NearbySearchFormState = {
  radiusKm: string;
  populationMin: string;
  populationMax: string;
  comparativeIndexMin: string;
  comparativeIndexMax: string;
  categoryCode: string;
  categoryIncidentMin: string;
  categoryIncidentMax: string;
  categoryRateMin: string;
  categoryRateMax: string;
  mapCategoryCode: string;
  mapEnvironmentalRadiusKm: string;
  limit: string;
  offset: string;
};

export type NearbyCityResult = {
  inseeCode: string;
  name: string;
  departmentCode: string;
  departmentName: string;
  regionCode: string;
  regionName: string;
  latitude: number;
  longitude: number;
  distanceKm: string | number;
  population: number | null;
  populationYear: number | null;
  published: {
    publishedCategoryCount: number;
    totalCategoryCount: number;
    coverageRatio: string | number | null;
  };
  comparativeIndex: {
    value: number | null;
    status: "comparable" | "insufficient-coverage" | "cohort-too-small" | "population-unavailable";
    completeness: "high" | "medium" | "low" | null;
    basketVersion: string;
    publishedBasketCategoryCount: number;
    basketCategoryCount: number;
    basketAvailability: Array<{ code: string; label: string; available: boolean }>;
    cohortSize: number;
    populationBand: string | null;
  };
  selectedCategory: {
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
  } | null;
};

export const defaultNearbySearchForm: NearbySearchFormState = {
  radiusKm: "50",
  populationMin: "",
  populationMax: "",
  comparativeIndexMin: "",
  comparativeIndexMax: "",
  categoryCode: "",
  categoryIncidentMin: "",
  categoryIncidentMax: "",
  categoryRateMin: "",
  categoryRateMax: "",
  mapCategoryCode: "",
  mapEnvironmentalRadiusKm: "",
  limit: "100",
  offset: "0"
};

export function createDefaultNearbySearchForm(): NearbySearchFormState {
  return { ...defaultNearbySearchForm };
}

const queryKeys: Array<keyof NearbySearchFormState> = [
  "radiusKm",
  "populationMin",
  "populationMax",
  "comparativeIndexMin",
  "comparativeIndexMax",
  "categoryCode",
  "categoryIncidentMin",
  "categoryIncidentMax",
  "categoryRateMin",
  "categoryRateMax",
  "mapCategoryCode",
  "limit",
  "offset"
];

export function buildNearbySearchUrl(
  originInseeCode: string,
  year: number,
  state: NearbySearchFormState
) {
  const params = new URLSearchParams({ year: String(year) });
  const hasSelectedCategory = state.categoryCode.trim() !== "";
  const environmentalRadius = state.mapEnvironmentalRadiusKm.trim();

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
    if (key === "mapCategoryCode" && environmentalRadius !== "") {
      continue;
    }

    const value = state[key].trim();
    if (value !== "") {
      params.set(key, value);
    }
  }

  if (environmentalRadius !== "") {
    params.set("environmentalRadiusKm", environmentalRadius);
  }

  return `/api/cities/${originInseeCode}/nearby?${params.toString()}`;
}

export function selectNearbyMapCriterion(
  state: NearbySearchFormState,
  criterion: NearbyMapCriterion,
  categoryCode = ""
): NearbySearchFormState {
  return {
    ...state,
    mapCategoryCode: criterion.type === "categoryRate" ? categoryCode : "",
    mapEnvironmentalRadiusKm:
      criterion.type === "environmentalRisk" ? String(criterion.radiusKm) : "",
    offset: "0"
  };
}

export function getNearbyMapCriterion(
  state: Pick<NearbySearchFormState, "mapCategoryCode" | "mapEnvironmentalRadiusKm">
): NearbyMapCriterion {
  const radius = ENVIRONMENTAL_RADII_KM.find(
    (candidate) => String(candidate) === state.mapEnvironmentalRadiusKm.trim()
  );
  if (radius !== undefined) {
    return { type: "environmentalRisk", radiusKm: radius as EnvironmentalRadiusKm };
  }

  if (state.mapCategoryCode.trim() !== "") {
    return { type: "categoryRate" };
  }

  return { type: "comparativeIndex" };
}

export function formatDistance(value: string | number) {
  return `${new Intl.NumberFormat("fr-FR", {
    minimumFractionDigits: Number(value) < 10 ? 1 : 0,
    maximumFractionDigits: 1
  }).format(Number(value))} km`;
}
