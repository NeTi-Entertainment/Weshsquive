export const EXPOSURE_INDEX_VERSION = "absolute-exposure-v1";
export const EXPOSURE_INDEX_CALIBRATION_YEAR = 2025;
export const EXPOSURE_INDEX_GUARDRAIL_COUNT = 10;
export const EXPOSURE_INDEX_GUARDRAIL_CAP = 35;

export const EXPOSURE_INDEX_ANCHORS = [
  {
    code: "ssmsi-78384436563146dc6167ea53b7b5e0cd",
    label: "Cambriolages de logement",
    denominator: "housing",
    countUnit: "Infraction",
    anchorRatePer1000: 16.047
  },
  {
    code: "ssmsi-74a195792dd119f60822e61df3587522",
    label: "Vols de véhicule",
    denominator: "population",
    countUnit: "Véhicule",
    anchorRatePer1000: 5.1964
  },
  {
    code: "ssmsi-d3e9d2e40d72b8850d5283eb73bdc928",
    label: "Vols dans les véhicules",
    denominator: "population",
    countUnit: "Véhicule",
    anchorRatePer1000: 13.2453
  },
  {
    code: "ssmsi-bf6b19b3e53b90f6594ec2e8303c5778",
    label: "Destructions et dégradations volontaires",
    denominator: "population",
    countUnit: "Infraction",
    anchorRatePer1000: 13.8213
  },
  {
    code: "ssmsi-a2601b900aa009440624697e1d74e4a9",
    label: "Violences physiques hors cadre familial",
    denominator: "population",
    countUnit: "Victime",
    anchorRatePer1000: 8.5257
  },
  {
    code: "ssmsi-bdbeb8ca73503f8264dab16159795328",
    label: "Trafic de stupéfiants",
    denominator: "population",
    countUnit: "Mis en cause",
    anchorRatePer1000: 5.1832
  }
] as const;

export type ExposureRiskBand = "very-low" | "low" | "medium" | "high" | "very-high" | "extreme";
export type ExposureRateDenominator = "population" | "housing" | "unknown";

export function isExposureIndexCategory(categoryCode: string): boolean {
  return EXPOSURE_INDEX_ANCHORS.some((category) => category.code === categoryCode);
}

export function normalizeExposureRate(
  categoryCode: string,
  ratePer1000: number | string | null,
  denominator: ExposureRateDenominator
): number | null {
  const anchor = EXPOSURE_INDEX_ANCHORS.find((category) => category.code === categoryCode);
  const rate = ratePer1000 === null ? null : Number(ratePer1000);
  if (
    !anchor ||
    denominator !== anchor.denominator ||
    rate === null ||
    !Number.isFinite(rate) ||
    rate < 0
  ) {
    return null;
  }

  return Number(Math.min(100, rate / anchor.anchorRatePer1000 * 100).toFixed(4));
}

export function getExposureRiskBand(value: number | null): ExposureRiskBand | "" {
  if (value === null || !Number.isFinite(value)) return "";
  if (value <= 10) return "very-low";
  if (value <= 35) return "low";
  if (value <= 50) return "medium";
  if (value <= 65) return "high";
  if (value <= 85) return "very-high";
  return "extreme";
}

type LowVolumeCount = {
  published: boolean;
  countUnit: string | null;
  count: number | null;
};

export type LowVolumeGuardrailInput = {
  burglary: LowVolumeCount;
  degradation: LowVolumeCount;
  publishedComponentCount: number;
};

export function applyLowVolumeExposureCap(
  score: number,
  input: LowVolumeGuardrailInput
): { value: number; applied: boolean } {
  const counts = [input.burglary, input.degradation];
  const validPublishedInfractions = counts.every((item) =>
    item.published && item.countUnit === "Infraction" && item.count !== null &&
    Number.isFinite(item.count) && item.count >= 0
  );
  const infractionCount = validPublishedInfractions
    ? counts.reduce((sum, item) => sum + item.count!, 0)
    : Number.POSITIVE_INFINITY;
  const eligible = validPublishedInfractions &&
    infractionCount < EXPOSURE_INDEX_GUARDRAIL_COUNT &&
    input.publishedComponentCount >= 5;
  const applied = eligible && score > EXPOSURE_INDEX_GUARDRAIL_CAP;

  return {
    value: applied ? EXPOSURE_INDEX_GUARDRAIL_CAP : score,
    applied
  };
}
