import {
  EXPOSURE_INDEX_ANCHORS,
  EXPOSURE_INDEX_CALIBRATION_YEAR,
  EXPOSURE_INDEX_GUARDRAIL_CAP,
  EXPOSURE_INDEX_GUARDRAIL_COUNT,
  EXPOSURE_INDEX_VERSION
} from "@/shared/exposure-index";

export const COMPARATIVE_INDEX_BASKET = EXPOSURE_INDEX_ANCHORS.map(({ code, label }) => ({ code, label }));
export const COMPARATIVE_INDEX_VERSION = EXPOSURE_INDEX_VERSION;

export type ComparativeIndexStatus = "available" | "unavailable";

export type ComparativeIndexProvenance =
  | "published-only"
  | "partially-estimated"
  | "estimated-only"
  | "unavailable";

export type ComparativeIndex = {
  value: number | null;
  status: ComparativeIndexStatus;
  provenance: ComparativeIndexProvenance;
  basketVersion: string | null;
  publishedComponentCount: number;
  estimatedComponentCount: number;
  availableComponentCount: number;
  coverageRatio: number;
  lowVolumeCapApplied: boolean;
  basketCategoryCount: number;
  basketAvailability: Array<{
    code: string;
    label: string;
    available: boolean;
    estimated: boolean;
  }>;
};

export type PublishedMetrics = {
  publishedCategoryCount: number;
  totalCategoryCount: number;
  coverageRatio: string | null;
};

export type ComparativeIndexColumns = {
  comparative_index: number | null;
  comparative_index_status: ComparativeIndexStatus | null;
  basket_version: string | null;
  published_basket_category_count: number | null;
  estimated_basket_category_count: number | null;
  effective_basket_category_count: number | null;
  basket_index_coverage: string | number | null;
  availability_mask: number | null;
  estimated_availability_mask: number | null;
  comparative_index_provenance: ComparativeIndexProvenance | null;
  low_volume_cap_applied: boolean | null;
};

export type PublishedMetricsColumns = {
  published_category_count: number | null;
  total_category_count: number | null;
  coverage_ratio: string | null;
};

export function mapComparativeIndex(row: ComparativeIndexColumns): ComparativeIndex {
  if (
    row.basket_version !== COMPARATIVE_INDEX_VERSION ||
    row.comparative_index_status === null ||
    row.comparative_index_provenance === null ||
    row.published_basket_category_count === null ||
    row.estimated_basket_category_count === null ||
    row.effective_basket_category_count === null ||
    row.availability_mask === null ||
    row.estimated_availability_mask === null ||
    row.low_volume_cap_applied === null
  ) {
    return unavailableComparativeIndex(row.basket_version ?? null);
  }

  const availableComponentCount = row.effective_basket_category_count;
  const isAvailable =
    row.comparative_index_status === "available" &&
    row.comparative_index !== null &&
    availableComponentCount > 0 &&
    row.comparative_index_provenance !== "unavailable";
  const publishedComponentCount = row.published_basket_category_count;
  const estimatedComponentCount = row.estimated_basket_category_count;
  const coverageRatio = row.basket_index_coverage == null
    ? availableComponentCount / EXPOSURE_INDEX_ANCHORS.length
    : Number(row.basket_index_coverage);
  const publishedMask = row.availability_mask;
  const estimatedMask = row.estimated_availability_mask;

  return {
    value: isAvailable ? Number(row.comparative_index) : null,
    status: isAvailable ? "available" : "unavailable",
    provenance: isAvailable ? row.comparative_index_provenance : "unavailable",
    basketVersion: row.basket_version,
    publishedComponentCount,
    estimatedComponentCount,
    availableComponentCount,
    coverageRatio: Number.isFinite(coverageRatio) ? coverageRatio : 0,
    lowVolumeCapApplied: isAvailable && row.low_volume_cap_applied,
    basketCategoryCount: EXPOSURE_INDEX_ANCHORS.length,
    basketAvailability: EXPOSURE_INDEX_ANCHORS.map((category, index) => {
      const published = (publishedMask & (1 << index)) !== 0;
      const estimated = (estimatedMask & (1 << index)) !== 0;
      return { code: category.code, label: category.label, available: published || estimated, estimated };
    })
  };
}

function unavailableComparativeIndex(basketVersion: string | null): ComparativeIndex {
  return {
    value: null,
    status: "unavailable",
    provenance: "unavailable",
    basketVersion,
    publishedComponentCount: 0,
    estimatedComponentCount: 0,
    availableComponentCount: 0,
    coverageRatio: 0,
    lowVolumeCapApplied: false,
    basketCategoryCount: EXPOSURE_INDEX_ANCHORS.length,
    basketAvailability: EXPOSURE_INDEX_ANCHORS.map((category) => ({
      code: category.code,
      label: category.label,
      available: false,
      estimated: false
    }))
  };
}

export function comparativeIndexProvenanceLabel(
  provenance: ComparativeIndexProvenance
): string {
  switch (provenance) {
    case "published-only":
      return "Données communales publiées";
    case "partially-estimated":
      return "Partiellement estimé";
    case "estimated-only":
      return "Entièrement estimé";
    case "unavailable":
      return "Indice indisponible";
  }
}

export function mapPublishedMetrics(row: PublishedMetricsColumns): PublishedMetrics {
  return {
    publishedCategoryCount: row.published_category_count ?? 0,
    totalCategoryCount: row.total_category_count ?? 0,
    coverageRatio: row.coverage_ratio
  };
}

export const comparativeIndexMetadata = {
  name: "Indice d’exposition calculé par l’application",
  version: COMPARATIVE_INDEX_VERSION,
  calibrationYear: EXPOSURE_INDEX_CALIBRATION_YEAR,
  basket: EXPOSURE_INDEX_ANCHORS,
  formula: "Moyenne à poids égal des scores de taux par catégorie : min(100, taux / ancre 2025 x 100).",
  colorThresholds: [10, 35, 50, 65, 85],
  guardrailCount: EXPOSURE_INDEX_GUARDRAIL_COUNT,
  guardrailCap: EXPOSURE_INDEX_GUARDRAIL_CAP,
  guardrail: "Plafond à 35 si les deux nombres publiés en unité Infraction totalisent moins de 10 et si au moins cinq catégories du panier sont publiées.",
  temporalSmoothing: false,
  estimatedValues: "Les compléments SSMSI ne servent qu’au calcul d’une composante estimée et ne sont jamais présentés comme une statistique communale."
};
