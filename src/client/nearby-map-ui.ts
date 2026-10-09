import { getPercentileBand } from "@/client/city-search-ui";
import type {
  EnvironmentalRadiusKm,
  EnvironmentalRiskSummary
} from "@/server/environmental-risk";

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

export type NearbyMapColorPoint = Pick<
  NearbyMapPoint,
  "comparativeIndex" | "categoryPercentile" | "categoryPublicationStatus" | "environmentalRisk"
>;

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
  point: NearbyMapColorPoint,
  criterion: NearbyMapCriterionInput
): string {
  const criterionType = typeof criterion === "string" ? criterion : criterion.type;

  if (criterionType === "categoryRate") {
    if (point.categoryPublicationStatus !== "published") return "";
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

    return getPercentileBand(summary.value / 100);
  }

  return getPercentileBand(
    point.comparativeIndex === null ? null : point.comparativeIndex / 100
  );
}

export function getNearbyMapPointColor(
  point: NearbyMapColorPoint,
  criterion: NearbyMapCriterionInput
): string {
  return MAP_BAND_COLORS[getNearbyMapPointBand(point, criterion)] ?? NEARBY_MAP_UNAVAILABLE_COLOR;
}
