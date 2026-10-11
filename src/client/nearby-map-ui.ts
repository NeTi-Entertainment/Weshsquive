import { getPercentileBand } from "@/client/city-search-ui";
import type {
  EnvironmentalRadiusKm,
  EnvironmentalRiskSummary
} from "@/server/environmental-risk";
import type {
  ComparativeIndex,
  ComparativeIndexProvenance
} from "@/server/comparative-index";
import { getExposureRiskBand } from "@/shared/exposure-index";

export type NearbyMapCriterion =
  | { type: "comparativeIndex" }
  | { type: "categoryRate" }
  | { type: "environmentalRisk"; radiusKm: EnvironmentalRadiusKm };
type NearbyMapCriterionInput =
  | NearbyMapCriterion
  | "comparativeIndex"
  | "categoryRate";

export type NearbyMapPoint = {
  inseeCode: string;
  name: string;
  latitude: number;
  longitude: number;
  distanceKm: string | number;
  population: number | null;
  populationYear: number | null;
  comparativeIndex: ComparativeIndex;
  categoryLabel: string | null;
  categoryRatePer1000: string | number | null;
  categoryPercentile: string | number | null;
  categoryExposureScore: string | number | null;
  categoryColorMode: "absolute-exposure" | "percentile" | null;
  categoryCountUnit: string | null;
  categoryRateDenominator: "population" | "housing" | "unknown";
  categoryPopulationDenominatorYear: number | null;
  categoryHousingDenominatorYear: number | null;
  categoryPublicationStatus: "published" | "masked" | "unknown" | null;
  environmentalRisk?: EnvironmentalRiskSummary | null;
};

export type NearbyMapColorPoint = Pick<
  NearbyMapPoint,
  | "comparativeIndex"
  | "categoryPercentile"
  | "categoryExposureScore"
  | "categoryColorMode"
  | "categoryPublicationStatus"
  | "environmentalRisk"
>;

export type ComparativeIndexVisualStyle = {
  fillColor: string;
  fillOpacity: number;
  borderOpacity: number;
  dashArray: string | null;
  borderWeight: number;
};

export const comparativeIndexProvenanceLegend = [
  "published-only",
  "historical-published",
  "partially-estimated",
  "estimated-only",
  "unavailable"
] as const satisfies readonly ComparativeIndexProvenance[];

const MAP_BAND_COLORS: Record<string, string> = {
  "very-low": "#0f6b4f",
  low: "#8fd19e",
  medium: "#f4e77d",
  high: "#eca154",
  "very-high": "#c84b3f",
  extreme: "#781f24"
};

export const NEARBY_MAP_UNAVAILABLE_COLOR = "#7b8794";

export function getComparativeIndexVisualStyle(
  value: number | null,
  provenance: ComparativeIndexProvenance
): ComparativeIndexVisualStyle {
  const band = value === null || !Number.isFinite(value)
    ? ""
    : getExposureRiskBand(value);
  const fillColor = provenance === "unavailable" || band === ""
    ? NEARBY_MAP_UNAVAILABLE_COLOR
    : MAP_BAND_COLORS[band] ?? NEARBY_MAP_UNAVAILABLE_COLOR;

  if (provenance === "unavailable" || fillColor === NEARBY_MAP_UNAVAILABLE_COLOR) {
    return {
      fillColor: NEARBY_MAP_UNAVAILABLE_COLOR,
      fillOpacity: 0.92,
      borderOpacity: 0.9,
      dashArray: null,
      borderWeight: 1
    };
  }

  switch (provenance) {
    case "published-only":
      return { fillColor, fillOpacity: 0.92, borderOpacity: 0.95, dashArray: null, borderWeight: 1.5 };
    case "historical-published":
      return { fillColor, fillOpacity: 0.8, borderOpacity: 0.95, dashArray: "4 3", borderWeight: 1.5 };
    case "partially-estimated":
      return { fillColor, fillOpacity: 0.68, borderOpacity: 0.9, dashArray: "6 4", borderWeight: 1.5 };
    case "estimated-only":
      return { fillColor, fillOpacity: 0.48, borderOpacity: 1, dashArray: "2 2", borderWeight: 2 };
  }
}

export function getNearbyMapPointVisualStyle(
  point: NearbyMapColorPoint,
  criterion: NearbyMapCriterionInput
): ComparativeIndexVisualStyle | null {
  const criterionType = typeof criterion === "string" ? criterion : criterion.type;
  return criterionType === "comparativeIndex"
    ? getComparativeIndexVisualStyle(point.comparativeIndex.value, point.comparativeIndex.provenance)
    : null;
}

export function formatEnvironmentalRiskNeighborProvenance(
  summary: EnvironmentalRiskSummary
): string[] {
  return [
    `Communes voisines avec indice communal de l’année cible : ${summary.publishedOnlyNeighborCount}`,
    `Communes voisines avec indice complété par l’historique : ${summary.historicalPublishedNeighborCount}`,
    `Communes voisines avec indice partiellement estimé : ${summary.partiallyEstimatedNeighborCount}`,
    `Communes voisines avec indice entièrement estimé : ${summary.estimatedOnlyNeighborCount}`,
    ...(summary.oldestSourceYear === null
      ? []
      : [`Année source la plus ancienne : ${summary.oldestSourceYear}`])
  ];
}

export function getNearbyMapPointBand(
  point: NearbyMapColorPoint,
  criterion: NearbyMapCriterionInput
): string {
  const criterionType = typeof criterion === "string" ? criterion : criterion.type;

  if (criterionType === "categoryRate") {
    if (point.categoryPublicationStatus !== "published") return "";
    if (point.categoryColorMode === "absolute-exposure") {
      const exposureScore = point.categoryExposureScore === null
        ? null
        : Number(point.categoryExposureScore);
      return getExposureRiskBand(exposureScore);
    }
    return getPercentileBand(point.categoryPercentile);
  }

  if (typeof criterion !== "string" && criterion.type === "environmentalRisk") {
    const summary = point.environmentalRisk;
    if (
      !summary ||
      summary.radiusKm !== criterion.radiusKm ||
      summary.status !== "comparable" ||
      summary.value === null
    ) {
      return "";
    }

    return getExposureRiskBand(summary.value);
  }

  if (point.comparativeIndex.provenance === "unavailable") return "";

  return getExposureRiskBand(point.comparativeIndex.value);
}

export function getNearbyMapPointColor(
  point: NearbyMapColorPoint,
  criterion: NearbyMapCriterionInput
): string {
  return MAP_BAND_COLORS[getNearbyMapPointBand(point, criterion)] ?? NEARBY_MAP_UNAVAILABLE_COLOR;
}
