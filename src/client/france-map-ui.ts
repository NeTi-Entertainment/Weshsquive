import type { CitySearchFormState } from "@/client/city-search-ui";
import { getNearbyMapPointColor, NEARBY_MAP_UNAVAILABLE_COLOR } from "@/client/nearby-map-ui";
import { getPropertyMarketColor } from "@/client/property-market-ui";
import type { EnvironmentalRadiusKm } from "@/server/environmental-risk";
import type { NationalMapPoint, NationalMapResult } from "@/server/national-map";
import { getNationalMapLevel } from "@/shared/map-levels";
import type { RentPropertyType, SalePropertyType } from "@/shared/property-market";

export { getNationalMapLevel } from "@/shared/map-levels";

export type NationalMapBounds = {
  west: number;
  south: number;
  east: number;
  north: number;
};

export type NationalMapCriterion =
  | { type: "comparativeIndex" }
  | { type: "categoryRate"; categoryCode: string }
  | { type: "environmentalRisk"; radiusKm: EnvironmentalRadiusKm }
  | { type: "salePrice"; propertyType: SalePropertyType }
  | { type: "rentPrice"; propertyType: RentPropertyType };

export type NationalMapFeature =
  | { type: "region" | "department" }
  | {
      type: "commune";
      point: Pick<
        NationalMapPoint,
        "comparativeIndex" | "categoryPercentile" | "categoryPublicationStatus" | "environmentalRisk" | "propertyMarket"
      >;
    };
type NationalMapColorPoint = Extract<NationalMapFeature, { type: "commune" }>["point"];

export const NATIONAL_MAP_GROUP_COLOR = "#526a7b";

export function getNationalMapFeatureColor(
  feature: NationalMapFeature,
  criterion: NationalMapCriterion
): string {
  if (feature.type !== "commune") return NATIONAL_MAP_GROUP_COLOR;
  return getNationalMapPointColor(feature.point, criterion);
}

export function getNationalMapPointColor(
  point: NationalMapColorPoint,
  criterion: NationalMapCriterion
): string {
  if (criterion.type === "salePrice" || criterion.type === "rentPrice") {
    return getPropertyMarketColor(point.propertyMarket);
  }
  if (
    criterion.type === "categoryRate" &&
    point.categoryPublicationStatus !== "published"
  ) {
    return NEARBY_MAP_UNAVAILABLE_COLOR;
  }
  const colorCriterion = criterion.type === "categoryRate" ? "categoryRate" : criterion;
  return getNearbyMapPointColor(point, colorCriterion);
}

export function formatNationalMapResultCount(result: NationalMapResult): string {
  if (result.level === "commune") {
    const count = result.points.length;
    return `${new Intl.NumberFormat("fr-FR").format(count)} ${count === 1 ? "commune" : "communes"} dans l’emprise visible`;
  }
  const count = result.groups.length;
  const noun = result.level === "region" ? "région" : "département";
  return `${new Intl.NumberFormat("fr-FR").format(count)} ${noun}${count === 1 ? "" : "s"} dans l’emprise visible`;
}

const FILTER_KEYS: Array<keyof CitySearchFormState> = [
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
  "categoryRateMax"
];

export function buildNationalMapUrl(
  form: CitySearchFormState,
  bounds: NationalMapBounds,
  zoom: number,
  criterion: NationalMapCriterion
): string {
  const params = new URLSearchParams();
  const categoryFilterActive = form.categoryCode.trim() !== "";
  for (const key of FILTER_KEYS) {
    if (
      !categoryFilterActive &&
      ["categoryIncidentMin", "categoryIncidentMax", "categoryRateMin", "categoryRateMax"].includes(key)
    ) {
      continue;
    }
    const value = form[key].trim();
    if (value !== "") params.set(key, value);
  }

  params.set("zoom", String(zoom));
  params.set("west", bounds.west.toFixed(5));
  params.set("south", bounds.south.toFixed(5));
  params.set("east", bounds.east.toFixed(5));
  params.set("north", bounds.north.toFixed(5));
  params.set("criterion", criterion.type);
  if (criterion.type === "categoryRate") {
    params.set("mapCategoryCode", criterion.categoryCode);
  } else if (criterion.type === "environmentalRisk") {
    params.set("environmentalRadiusKm", String(criterion.radiusKm));
  } else if (criterion.type === "salePrice" || criterion.type === "rentPrice") {
    params.set("marketPropertyType", criterion.propertyType);
  }

  return `/api/cities/map?${params.toString()}`;
}

export function mapLevelChanged(previousZoom: number, nextZoom: number): boolean {
  return getNationalMapLevel(previousZoom) !== getNationalMapLevel(nextZoom);
}
