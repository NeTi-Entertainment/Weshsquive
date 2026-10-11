import { EXPOSURE_INDEX_ANCHORS, type ExposureComponentSource } from "@/shared/exposure-index";

export const EXPOSURE_ALERT_COMPONENT_THRESHOLD = 65;
export const EXPOSURE_ALERT_MINIMUM_COMPONENTS = 2;
export const EXPOSURE_ALERT_LABEL =
  "Plusieurs catégories présentent une exposition élevée malgré un indice global modéré.";

export type ExposureAlertComponentInput = {
  code: string;
  label: string;
  exposureScore: number | string | null;
  exposureSourceYear: number | null;
  exposureProvenance: ExposureComponentSource | null;
};

export type ExposureAlertComponent = {
  code: string;
  label: string;
  score: number;
  sourceYear: number | null;
  provenance: Exclude<ExposureComponentSource, "unavailable">;
};

export type MultipleHighExposureAlert = {
  label: typeof EXPOSURE_ALERT_LABEL;
  components: ExposureAlertComponent[];
};

const basketCategoryCodes: ReadonlySet<string> = new Set(
  EXPOSURE_INDEX_ANCHORS.map((category) => category.code)
);

export function getMultipleHighExposureAlert(
  components: readonly ExposureAlertComponentInput[]
): MultipleHighExposureAlert | null {
  const elevated = components.flatMap((component): ExposureAlertComponent[] => {
    const score = component.exposureScore === null ? null : Number(component.exposureScore);
    if (
      !basketCategoryCodes.has(component.code) ||
      score === null ||
      !Number.isFinite(score) ||
      score < EXPOSURE_ALERT_COMPONENT_THRESHOLD ||
      component.exposureProvenance === null ||
      component.exposureProvenance === "unavailable"
    ) {
      return [];
    }

    return [{
      code: component.code,
      label: component.label,
      score,
      sourceYear: component.exposureSourceYear,
      provenance: component.exposureProvenance
    }];
  });

  return elevated.length < EXPOSURE_ALERT_MINIMUM_COMPONENTS
    ? null
    : { label: EXPOSURE_ALERT_LABEL, components: elevated };
}
