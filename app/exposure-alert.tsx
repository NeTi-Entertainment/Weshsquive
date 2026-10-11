import {
  exposureComponentSourceLabel,
  formatComparativeIndex
} from "@/client/city-search-ui";
import type { MultipleHighExposureAlert } from "@/shared/exposure-alert";

export function ExposureAlertBadge({
  alert,
  targetYear
}: {
  alert: MultipleHighExposureAlert | null;
  targetYear: number;
}) {
  if (!alert) return null;

  const details = alert.components.map((component) =>
    `${component.label}: ${formatComparativeIndex(component.score)} · ${exposureComponentSourceLabel(
      component.provenance,
      component.sourceYear,
      targetYear
    )}`
  ).join("; ");

  return (
    <span
      className="exposure-alert-badge"
      role="img"
      aria-label={alert.label}
      title={`${alert.label} ${details}`}
    >
      ⚠
    </span>
  );
}

export function ExposureAlertDetails({
  alert,
  targetYear
}: {
  alert: MultipleHighExposureAlert | null;
  targetYear: number;
}) {
  if (!alert) return null;

  return (
    <div className="exposure-alert-details" role="note">
      <strong><span aria-hidden="true">⚠</span> {alert.label}</strong>
      <ul>
        {alert.components.map((component) => (
          <li key={component.code}>
            {component.label}: {formatComparativeIndex(component.score)} · {exposureComponentSourceLabel(
              component.provenance,
              component.sourceYear,
              targetYear
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
