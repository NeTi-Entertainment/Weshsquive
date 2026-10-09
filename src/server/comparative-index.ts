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

export const COMPARATIVE_INDEX_VERSION = "residential-risk-v1";
export const COMPARATIVE_INDEX_MIN_CATEGORIES = 3;
export const COMPARATIVE_INDEX_MIN_COHORT_SIZE = 50;

export type ComparativeIndexStatus =
  | "comparable"
  | "insufficient-coverage"
  | "cohort-too-small"
  | "population-unavailable";

export type ComparativeIndexCompleteness = "high" | "medium" | "low";

export type ComparativeIndex = {
  value: number | null;
  status: ComparativeIndexStatus;
  completeness: ComparativeIndexCompleteness | null;
  basketVersion: string;
  publishedBasketCategoryCount: number;
  basketCategoryCount: number;
  basketAvailability: Array<{
    code: string;
    label: string;
    available: boolean;
  }>;
  cohortSize: number;
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
  // Legacy database name: this value measures basket completeness, not statistical confidence.
  comparative_index_confidence: ComparativeIndexCompleteness | null;
  basket_version: string | null;
  published_basket_category_count: number | null;
  availability_mask: number | null;
  cohort_size: number | null;
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
  const status = row.comparative_index_status ??
    (population === null || population <= 0 ? "population-unavailable" : "insufficient-coverage");

  return {
    value: row.comparative_index,
    status,
    completeness: row.comparative_index_confidence,
    basketVersion: row.basket_version ?? COMPARATIVE_INDEX_VERSION,
    publishedBasketCategoryCount: row.published_basket_category_count ?? 0,
    basketCategoryCount: COMPARATIVE_INDEX_BASKET.length,
    basketAvailability: COMPARATIVE_INDEX_BASKET.map((category, index) => ({
      ...category,
      available: ((row.availability_mask ?? 0) & (1 << index)) !== 0
    })),
    cohortSize: row.cohort_size ?? 0,
    populationBand: row.population_band
  };
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
  minimumPublishedCategories: COMPARATIVE_INDEX_MIN_CATEGORIES,
  minimumCohortSize: COMPARATIVE_INDEX_MIN_COHORT_SIZE
};
