import type { EnvironmentalRiskStatus, EnvironmentalRiskSummary } from "@/server/environmental-risk";

export function formatEnvironmentalRiskValue(value: number | null): string {
  if (value === null) return "Non disponible";

  return new Intl.NumberFormat("fr-FR", {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1
  }).format(value);
}

export function formatEnvironmentalRiskStatus(status: EnvironmentalRiskStatus): string {
  switch (status) {
    case "comparable":
      return "Indice calculé";
    case "insufficient-coverage":
      return "Couverture insuffisante";
    case "no-neighbors":
      return "Aucune commune dans ce rayon";
    case "coordinates-unavailable":
      return "Coordonnées indisponibles";
  }
}

export function formatEnvironmentalRiskProvenance(
  provenance: EnvironmentalRiskSummary["provenance"]
): string {
  switch (provenance) {
    case "published-only":
      return "Basé sur des indices publiés";
    case "partially-estimated":
      return "Contient des indices estimés";
    case "unavailable":
      return "Indice indisponible";
  }
}

export function formatEnvironmentalRiskCoverage(ratio: number | null): string {
  if (ratio === null) return "Non renseignée";

  return new Intl.NumberFormat("fr-FR", {
    style: "percent",
    maximumFractionDigits: 0
  }).format(ratio);
}
