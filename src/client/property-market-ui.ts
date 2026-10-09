import { getPercentileBand } from "@/client/city-search-ui";
import { NEARBY_MAP_UNAVAILABLE_COLOR } from "@/client/nearby-map-ui";
import type {
  PropertyMarketDisplayStatus,
  PropertyMarketMetric,
  PropertyMarketPropertyType
} from "@/shared/property-market";

const PROPERTY_MARKET_COLORS: Record<string, string> = {
  "very-low": "#d7eef8",
  low: "#9bd6ea",
  medium: "#52abc8",
  high: "#2777b5",
  "very-high": "#4b4fa3",
  extreme: "#692b83"
};

export const PROPERTY_MARKET_LEGEND_BANDS = [
  { className: "market-band-very-low", label: "0–20", color: "#d7eef8" },
  { className: "market-band-low", label: "20–40", color: "#9bd6ea" },
  { className: "market-band-medium", label: "40–60", color: "#52abc8" },
  { className: "market-band-high", label: "60–80", color: "#2777b5" },
  { className: "market-band-very-high", label: "80–95", color: "#4b4fa3" },
  { className: "market-band-extreme", label: "95–100", color: "#692b83" }
] as const;

export function getPropertyMarketColor(metric: PropertyMarketMetric | null): string {
  if (!metric || metric.status !== "published") return NEARBY_MAP_UNAVAILABLE_COLOR;
  return PROPERTY_MARKET_COLORS[getPercentileBand(metric.nationalPercentile)]
    ?? NEARBY_MAP_UNAVAILABLE_COLOR;
}

export function formatPropertyMarketValue(metric: PropertyMarketMetric): string {
  if (metric.valuePerM2 === null) return propertyMarketStatusLabel(metric.status);
  const value = Number(metric.valuePerM2);
  if (!Number.isFinite(value)) return "Valeur immobilière indisponible";
  const formatted = new Intl.NumberFormat("fr-FR", {
    minimumFractionDigits: metric.kind === "rent" ? 2 : 0,
    maximumFractionDigits: metric.kind === "rent" ? 2 : 0
  }).format(value);
  return metric.kind === "rent" ? `${formatted} €/m²/mois` : `${formatted} €/m²`;
}

export function formatPropertyMarketInterval(metric: PropertyMarketMetric): string | null {
  if (
    metric.kind !== "rent"
    || metric.lowerBoundPerM2 === null
    || metric.upperBoundPerM2 === null
  ) {
    return null;
  }
  const lower = Number(metric.lowerBoundPerM2);
  const upper = Number(metric.upperBoundPerM2);
  if (!Number.isFinite(lower) || !Number.isFinite(upper)) return null;
  const format = new Intl.NumberFormat("fr-FR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  });
  return `Intervalle publié : ${format.format(lower)} à ${format.format(upper)} €/m²/mois`;
}

export function propertyMarketStatusLabel(status: PropertyMarketDisplayStatus): string {
  switch (status) {
    case "published": return "Donnée publiée";
    case "source-uncovered": return "Zone non couverte par la source";
    case "no-data": return "Aucune donnée disponible";
    case "insufficient-sample": return "Échantillon de ventes insuffisant";
    case "non-communal-estimate": return "Estimation établie sur une maille plus large";
    case "insufficient-quality": return "Qualité statistique insuffisante";
    case "invalid-value": return "Valeur source inexploitable";
    case "year-unavailable": return "Données immobilières indisponibles pour cette année";
  }
}

export function propertyTypeLabel(propertyType: PropertyMarketPropertyType): string {
  if (propertyType === "all") return "Tous logements";
  if (propertyType === "apartment") return "Appartements";
  return "Maisons";
}

export function propertyMarketSourceLabel(metric: PropertyMarketMetric): string {
  if (metric.sourceSystem === "dvf-geolocated") return "DVF, traitement data.gouv.fr";
  if (metric.sourceSystem === "anil-rent-map") return "Estimations ANIL, données SeLoger et leboncoin";
  return "Source immobilière indisponible";
}
