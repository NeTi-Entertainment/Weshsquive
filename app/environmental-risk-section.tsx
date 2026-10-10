import { getComparativeIndexClassName } from "@/client/city-search-ui";
import {
  formatEnvironmentalRiskCoverage,
  formatEnvironmentalRiskProvenance,
  formatEnvironmentalRiskStatus,
  formatEnvironmentalRiskValue
} from "@/client/environmental-risk-ui";
import type { EnvironmentalRiskSummary } from "@/server/environmental-risk";

type EnvironmentalRiskSectionProps = {
  summaries: EnvironmentalRiskSummary[];
};

export default function EnvironmentalRiskSection({ summaries }: EnvironmentalRiskSectionProps) {
  return (
    <section className="environmental-risk-section" aria-labelledby="environmental-risk-title">
      <div className="environmental-risk-heading">
        <h2 id="environmental-risk-title">Environnement statistique</h2>
      </div>
      <div className="environmental-risk-table-frame">
        <table className="environmental-risk-table">
          <thead>
            <tr>
              <th scope="col">Rayon</th>
              <th scope="col">Indice environnemental</th>
              <th scope="col">Voisines avec indice / total</th>
              <th scope="col">Couverture pondérée</th>
            </tr>
          </thead>
          <tbody>
            {summaries.map((summary) => (
              <tr key={summary.radiusKm}>
                <th scope="row">{summary.radiusKm} km</th>
                <td>
                  <div className="environmental-risk-value-cell">
                    <strong
                      className={`environmental-risk-score${summary.value === null ? "" : ` ${getComparativeIndexClassName(summary.value)}`}`}
                    >
                      {formatEnvironmentalRiskValue(summary.value)}
                    </strong>
                    {summary.value !== null && <span className="environmental-risk-scale">/ 100</span>}
                  </div>
                  <small>{formatEnvironmentalRiskStatus(summary.status)}</small>
                  <small>{formatEnvironmentalRiskProvenance(summary.provenance)}</small>
                </td>
                <td aria-label={`${summary.scoredNeighborCount} communes avec indice sur ${summary.totalNeighborCount} communes voisines`}>
                  {summary.scoredNeighborCount} / {summary.totalNeighborCount}
                  <small className="environmental-risk-provenance-counts">
                    Publiés : {summary.publishedOnlyNeighborCount} · partiellement estimés : {summary.partiallyEstimatedNeighborCount} · entièrement estimés : {summary.estimatedOnlyNeighborCount}
                  </small>
                </td>
                <td>{formatEnvironmentalRiskCoverage(summary.weightedCoverageRatio)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="environmental-risk-note">
        Cette moyenne, calculée par l’application à partir des indices d’exposition des communes voisines et pondérée par la distance,
        décrit une exposition statistique. Ce n’est ni une statistique officielle du SSMSI, ni un percentile environnemental,
        ni une probabilité individuelle ou une garantie de sécurité. Les compléments départementaux SSMSI servent uniquement de fallback estimatif pour les catégories masquées; ils ne sont jamais affichés comme des valeurs communales.
      </p>
    </section>
  );
}
