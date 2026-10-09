import { getPercentileBand } from "@/client/city-search-ui";
import type { EnvironmentalRiskSummary } from "@/server/environmental-risk";

export type NearbyMapCriterion = "comparativeIndex" | "categoryRate";

export type NearbyMapPoint = {
  inseeCode: string;
  name: string;
  latitude: number;
  longitude: number;
  distanceKm: string | number;
  population: number | null;
  populationYear: number | null;
  comparativeIndex: number | null;
  comparativeIndexStatus: string;
  comparativeIndexCompleteness: "high" | "medium" | "low" | null;
  categoryLabel: string | null;
  categoryRatePer1000: string | number | null;
  categoryPercentile: string | number | null;
  categoryCountUnit: string | null;
  categoryRateDenominator: "population" | "housing" | "unknown";
  categoryPopulationDenominatorYear: number | null;
  categoryHousingDenominatorYear: number | null;
  categoryPublicationStatus: "published" | "masked" | "unknown" | null;
  environmentalRisk?: EnvironmentalRiskSummary | null;
};

const MAP_BAND_COLORS: Record<string, string> = {
  "very-low": "#0f6b4f",
  low: "#8fd19e",
  medium: "#f4e77d",
  high: "#eca154",
  "very-high": "#c84b3f",
  extreme: "#781f24"
};

export const NEARBY_MAP_UNAVAILABLE_COLOR = "#7b8794";

export function getNearbyMapPointBand(
  point: NearbyMapPoint,
  criterion: NearbyMapCriterion
): string {
  if (criterion === "categoryRate") {
    if (point.categoryPublicationStatus !== "published") return "";
    return getPercentileBand(point.categoryPercentile);
  }

  return getPercentileBand(
    point.comparativeIndex === null ? null : point.comparativeIndex / 100
  );
}

export function getNearbyMapPointColor(
  point: NearbyMapPoint,
  criterion: NearbyMapCriterion
): string {
  return MAP_BAND_COLORS[getNearbyMapPointBand(point, criterion)] ?? NEARBY_MAP_UNAVAILABLE_COLOR;
}
