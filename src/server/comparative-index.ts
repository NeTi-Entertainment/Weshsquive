export const COMPARATIVE_INDEX_BASKET = [
  { code: "ssmsi-78384436563146dc6167ea53b7b5e0cd", label: "Cambriolages de logement" },
  { code: "ssmsi-74a195792dd119f60822e61df3587522", label: "Vols de véhicule" },
  { code: "ssmsi-d3e9d2e40d72b8850d5283eb73bdc928", label: "Vols dans les véhicules" },
  { code: "ssmsi-bf6b19b3e53b90f6594ec2e8303c5778", label: "Destructions et dégradations volontaires" },
  {
    code: "ssmsi-a2601b900aa009440624697e1d74e4a9",
    label: "Violences physiques hors cadre familial"
  },
  { code: "ssmsi-bdbeb8ca73503f8264dab16159795328", label: "Trafic de stupéfiants" }
] as const;

export const COMPARATIVE_INDEX_VERSION = "residential-risk-v2";
export const COMPARATIVE_INDEX_MIN_CATEGORIES = 3;
export const COMPARATIVE_INDEX_MIN_COHORT_SIZE = 50;

export type ComparativeIndexStatus =
  | "comparable"
  | "insufficient-coverage"
  | "reference-cohort-too-small"
  | "population-unavailable";

export type ComparativeIndexProvenance =
  | "published-only"
  | "partially-estimated"
  | "estimated-only"
  | "unavailable";

export type ComparativeIndexCompleteness = "high" | "medium" | "low";

export type ComparativeIndex = {
  value: number | null;
  status: ComparativeIndexStatus;
  provenance: ComparativeIndexProvenance;
  completeness: ComparativeIndexCompleteness | null;
  basketVersion: string | null;
  publishedComponentCount: number;
  estimatedComponentCount: number;
  comparableComponentCount: number;
  minimumReferenceCohortSize: number;
  basketCategoryCount: number;
  basketAvailability: Array<{
    code: string;
    label: string;
    available: boolean;
    estimated: boolean;
  }>;
  populationBand: string | null;
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
  comparable_basket_category_count: number | null;
  availability_mask: number | null;
  estimated_availability_mask: number | null;
  minimum_reference_cohort_size: number | null;
  comparative_index_provenance: ComparativeIndexProvenance | null;
  population_band: string | null;
};

export type PublishedMetricsColumns = {
  published_category_count: number | null;
  total_category_count: number | null;
  coverage_ratio: string | null;
};

export function mapComparativeIndex(
  row: ComparativeIndexColumns,
  population: number | null
): ComparativeIndex {
  if (
    row.basket_version !== COMPARATIVE_INDEX_VERSION ||
    row.comparative_index_status == null ||
    row.comparative_index_provenance == null ||
    row.published_basket_category_count == null ||
    row.estimated_basket_category_count == null ||
    row.comparable_basket_category_count == null ||
    row.availability_mask == null ||
    row.estimated_availability_mask == null ||
    row.minimum_reference_cohort_size == null
  ) {
    return unavailableComparativeIndex(
      population === null || population <= 0
        ? "population-unavailable"
        : "insufficient-coverage",
      row.basket_version ?? null,
      row.population_band ?? null
    );
  }

  const comparableComponentCount = row.comparable_basket_category_count ?? 0;
  const isComparable =
    row.comparative_index_status === "comparable" &&
    row.comparative_index !== null &&
    row.comparative_index !== undefined &&
    row.comparative_index_provenance !== "unavailable" &&
    comparableComponentCount >= COMPARATIVE_INDEX_MIN_CATEGORIES;
  const status = row.comparative_index_status === "comparable" && !isComparable
    ? "insufficient-coverage"
    : row.comparative_index_status;
  const completeness = !isComparable
    ? null
    : comparableComponentCount >= 6
      ? "high"
      : comparableComponentCount >= 4
        ? "medium"
        : comparableComponentCount === 3
          ? "low"
          : null;
  const publishedComponentCount = row.published_basket_category_count ?? 0;
  const minimumReferenceCohortSize = row.minimum_reference_cohort_size ?? 0;

  return {
    value: isComparable ? row.comparative_index ?? null : null,
    status,
    provenance: isComparable ? row.comparative_index_provenance ?? "unavailable" : "unavailable",
    completeness,
    basketVersion: row.basket_version ?? COMPARATIVE_INDEX_VERSION,
    publishedComponentCount,
    estimatedComponentCount: row.estimated_basket_category_count ?? 0,
    comparableComponentCount,
    minimumReferenceCohortSize,
    basketCategoryCount: COMPARATIVE_INDEX_BASKET.length,
    basketAvailability: COMPARATIVE_INDEX_BASKET.map((category, index) => {
      const published = ((row.availability_mask ?? 0) & (1 << index)) !== 0;
      const estimated = ((row.estimated_availability_mask ?? 0) & (1 << index)) !== 0;
      return { ...category, available: published || estimated, estimated };
    }),
    populationBand: row.population_band ?? null
  };
}

function unavailableComparativeIndex(
  status: Exclude<ComparativeIndexStatus, "comparable">,
  basketVersion: string | null,
  populationBand: string | null
): ComparativeIndex {
  return {
    value: null,
    status,
    provenance: "unavailable",
    completeness: null,
    basketVersion,
    publishedComponentCount: 0,
    estimatedComponentCount: 0,
    comparableComponentCount: 0,
    minimumReferenceCohortSize: 0,
    basketCategoryCount: COMPARATIVE_INDEX_BASKET.length,
    basketAvailability: COMPARATIVE_INDEX_BASKET.map((category) => ({
      ...category,
      available: false,
      estimated: false
    })),
    populationBand
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
  version: COMPARATIVE_INDEX_VERSION,
  basket: COMPARATIVE_INDEX_BASKET,
  minimumComparableComponents: COMPARATIVE_INDEX_MIN_CATEGORIES,
  minimumReferenceCohortSize: COMPARATIVE_INDEX_MIN_COHORT_SIZE
};
