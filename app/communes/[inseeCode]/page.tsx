import Link from "next/link";
import { notFound } from "next/navigation";

import {
  comparativeIndexComponentCountLabel,
  comparativeIndexProvenanceLabel,
  describeComparativeIndex,
  describeBasketAvailability,
  formatComparativeIndex,
  formatCategoryRate,
  formatCoverage,
  formatInteger,
  formatPopulation,
  formatRate,
  formatComparisonCoverage,
  getComparativeIndexClassName
} from "@/client/city-search-ui";
import { exposureComponentSourceLabel } from "@/server/comparative-index";
import {
  getCityDetail,
  parseCityDetailParams,
  type CityDetail
} from "@/server/city-detail";
import { pool } from "@/server/db";

import EnvironmentalRiskSection from "../../environmental-risk-section";
import NearbyCitiesPanel from "../../nearby-cities-panel";
import { ExposureAlertDetails } from "../../exposure-alert";

type CityDetailPageProps = {
  params: Promise<{ inseeCode: string }>;
  searchParams: Promise<{ year?: string | string[]; categoryCode?: string | string[] }>;
};

export default async function CityDetailPage({ params, searchParams }: CityDetailPageProps) {
  const { inseeCode } = await params;
  const requestedSearchParams = await searchParams;
  const year = Array.isArray(requestedSearchParams.year)
    ? requestedSearchParams.year[0]
    : requestedSearchParams.year;
  const categoryCode = Array.isArray(requestedSearchParams.categoryCode)
    ? requestedSearchParams.categoryCode[0]
    : requestedSearchParams.categoryCode;
  const queryParams = new URLSearchParams();

  if (year) {
    queryParams.set("year", year);
  }
  if (categoryCode) {
    queryParams.set("categoryCode", categoryCode);
  }

  let detailParams;

  try {
    detailParams = parseCityDetailParams(inseeCode, queryParams);
  } catch {
    notFound();
  }

  const city = await getCityDetail(pool, detailParams);

  if (!city) {
    notFound();
  }

  const selectedHistory = city.historyByCategory.find(
    (category) => category.code === city.selectedHistoryCategoryCode
  );
  const selectedComparison = city.comparisons.find(
    (category) => category.code === city.selectedHistoryCategoryCode
  );
  const availableYears = Array.from(
    new Set([
      city.year,
      ...city.historyByCategory.flatMap((category) =>
        category.observations.map((observation) => observation.year)
      )
    ])
  ).sort((left, right) => right - left);
  const selectedHistoryObservations = selectedHistory?.observations ?? [];
  const historicalMaxima = new Map<string, number>();
  for (const observation of selectedHistoryObservations) {
    const seriesKey = `${observation.countUnit ?? ""}|${observation.rateDenominator}`;
    historicalMaxima.set(
      seriesKey,
      Math.max(historicalMaxima.get(seriesKey) ?? 0, Number(observation.ratePer1000 ?? 0))
    );
  }

  return (
    <main className="app-shell detail-shell">
      <header className="detail-header">
        <Link className="back-link" href="/">
          ← Retour à la recherche
        </Link>
        <div className="detail-heading">
          <div>
            <h1>{city.name}</h1>
            <p>
              {city.departmentName} ({city.departmentCode}) · {city.regionName}
            </p>
          </div>
          <nav className="year-navigation" aria-label="Années disponibles">
            {availableYears.map((availableYear) => (
              <Link
                key={availableYear}
                className={availableYear === city.year ? "year-link active-year" : "year-link"}
                href={`/communes/${city.inseeCode}?year=${availableYear}${city.selectedHistoryCategoryCode ? `&categoryCode=${encodeURIComponent(city.selectedHistoryCategoryCode)}` : ""}`}
                aria-current={availableYear === city.year ? "page" : undefined}
              >
                {availableYear}
              </Link>
            ))}
          </nav>
        </div>
      </header>

      <section className="metric-grid" aria-label="Synthèse communale">
        <article className="metric-card">
          <span>Population</span>
          <strong>{formatPopulation(city.population)}</strong>
          <small>Recensement {city.populationYear ?? "non renseigné"}</small>
        </article>
        <article className="metric-card">
          <span>Couverture des catégories</span>
          <strong>
            {city.published.publishedCategoryCount} / {city.published.totalCategoryCount}
          </strong>
          <small>
            {formatCoverage(
              city.published.publishedCategoryCount,
              city.published.totalCategoryCount
            )}
          </small>
        </article>
        <article
          className={`metric-card metric-card-index ${getComparativeIndexClassName(city.comparativeIndex.value)}`}
          title={`${describeComparativeIndex(city.comparativeIndex)} ${describeBasketAvailability(city.comparativeIndex.basketAvailability)}`}
          aria-label={`Indice ${formatComparativeIndex(city.comparativeIndex.value)}. ${describeComparativeIndex(city.comparativeIndex)} ${describeBasketAvailability(city.comparativeIndex.basketAvailability)}`}
        >
          <span>Indice d’exposition calculé par l’application · {city.year}</span>
          <strong>{formatComparativeIndex(city.comparativeIndex.value)}</strong>
          <small>
            {comparativeIndexProvenanceLabel(city.comparativeIndex.provenance, city.year)}
          </small>
          {city.comparativeIndex.oldestSourceYear !== null && city.comparativeIndex.oldestSourceYear < city.year ? (
            <small>Donnée communale la plus ancienne : {city.comparativeIndex.oldestSourceYear}</small>
          ) : null}
          <small>
            {comparativeIndexComponentCountLabel(city.comparativeIndex)}
          </small>
          {city.comparativeIndex.lowVolumeCapApplied ? <small>Plafond faible volume appliqué</small> : null}
          <small>Échelle fixe fondée sur les taux par catégorie; ce n’est pas une statistique officielle.</small>
        </article>
      </section>

      <ExposureAlertDetails
        alert={city.multipleHighExposureAlert}
        targetYear={city.year}
      />

      <EnvironmentalRiskSection summaries={city.environmentalRisk} />

      <section className="history-section" aria-labelledby="history-title">
        <div className="history-heading">
          <div>
            <h2 id="history-title">Historique annuel</h2>
            <p>Valeurs SSMSI annuelles pour une catégorie</p>
          </div>
          <form className="history-category-form" method="get">
            <input type="hidden" name="year" value={city.year} />
            <label>
              Catégorie
              <select name="categoryCode" defaultValue={city.selectedHistoryCategoryCode ?? ""}>
                {city.historyByCategory.map((category) => (
                  <option key={category.code} value={category.code}>{category.label}</option>
                ))}
              </select>
            </label>
            <button type="submit" disabled={!city.historyByCategory.length}>Afficher</button>
          </form>
          <span>{selectedHistoryObservations.length} année{selectedHistoryObservations.length > 1 ? "s" : ""}</span>
        </div>
        {selectedHistoryObservations.length === 0 ? (
          <p className="empty-detail">Aucun historique disponible pour cette commune.</p>
        ) : (
          <div className="history-chart">
            {selectedHistoryObservations.map((historyItem, index) => {
              const historicalRate = historyItem.ratePer1000 === null
                ? null
                : Number(historyItem.ratePer1000);
              const seriesKey = `${historyItem.countUnit ?? ""}|${historyItem.rateDenominator}`;
              const maximumHistoricalRate = historicalMaxima.get(seriesKey) ?? 0;
              const previous = selectedHistoryObservations[index - 1];
              const startsNewSegment = index > 0 &&
                (previous.countUnit !== historyItem.countUnit ||
                  previous.rateDenominator !== historyItem.rateDenominator);
              const barHeight = historicalRate === null || maximumHistoricalRate === 0
                ? 0
                : Math.max(5, (historicalRate / maximumHistoricalRate) * 100);

              return (
                <Link
                  className={`${historyItem.year === city.year ? "history-item active-history-item" : "history-item"}${startsNewSegment ? " history-segment-start" : ""}`}
                  href={`/communes/${city.inseeCode}?year=${historyItem.year}${city.selectedHistoryCategoryCode ? `&categoryCode=${encodeURIComponent(city.selectedHistoryCategoryCode)}` : ""}`}
                  key={historyItem.year}
                  title={`${formatInteger(historyItem.incidentCount)} ${historyItem.countUnit ?? "Unité inconnue"} · ${formatCategoryRate(
                    historyItem.ratePer1000,
                    historyItem.rateDenominator,
                    historyItem.populationDenominatorYear,
                    historyItem.housingDenominatorYear
                  )}`}
                  aria-label={`${selectedHistory?.label ?? "Catégorie"}, ${historyItem.year}: ${formatInteger(historyItem.incidentCount)} ${historyItem.countUnit ?? "Unité inconnue"}; ${formatCategoryRate(
                    historyItem.ratePer1000,
                    historyItem.rateDenominator,
                    historyItem.populationDenominatorYear,
                    historyItem.housingDenominatorYear
                  )}`}
                >
                  <strong>{formatRate(historyItem.ratePer1000)}</strong>
                  <div className="history-bar-track" aria-hidden="true">
                    <span style={{ height: `${barHeight}%` }} />
                  </div>
                  <b>{historyItem.year}</b>
                  <small>{formatInteger(historyItem.incidentCount)} {historyItem.countUnit ?? "Unité inconnue"}</small>
                  <small>{formatCategoryRate(
                    historyItem.ratePer1000,
                    historyItem.rateDenominator,
                    historyItem.populationDenominatorYear,
                    historyItem.housingDenominatorYear
                  )}</small>
                </Link>
              );
            })}
          </div>
        )}
      </section>

      <div className="detail-columns">
        <section className="detail-section" aria-labelledby="comparison-title">
          <div className="section-heading">
            <div>
              <h2 id="comparison-title">Comparaison territoriale</h2>
              <p>Comparaison du même indicateur, de la même unité et de la même base</p>
            </div>
          </div>
          <p>
            Les taux départemental, régional et France sont calculés par l’application sur les seules communes
            dont la valeur est publiée ; ce ne sont pas les agrégats territoriaux officiels du SSMSI.
          </p>
          {selectedComparison ? (
            <>
              <p>{selectedComparison.label} · {selectedComparison.countUnit ?? "Unité inconnue"}</p>
              <div className="comparison-list">
                {selectedComparison.scopes.map((scope) => (
                  <div className="comparison-row" key={scope.scope}>
                    <div className="comparison-copy">
                      <span>{comparisonScopeLabel(scope.scope)}</span>
                      <strong>{formatRate(scope.ratePer1000)}</strong>
                      <small>{comparisonBasis(selectedComparison.rateDenominator, scope.denominatorYears)}</small>
                      <small>{formatComparisonCoverage(scope.publishedCityCount, scope.totalCityCount)}</small>
                    </div>
                  </div>
                ))}
              </div>
            </>
          ) : (
            <p className="empty-detail">Aucune base comparable publiée pour cette catégorie et cette année.</p>
          )}
        </section>

        <section className="detail-section category-section" aria-labelledby="categories-title">
          <div className="section-heading">
            <div>
              <h2 id="categories-title">Détail par catégorie</h2>
              <p>{city.categories.length} catégories pour {city.year}</p>
            </div>
          </div>
          {city.categories.length === 0 ? (
            <p className="empty-detail">Aucune statistique disponible pour cette année.</p>
          ) : (
            <div className="detail-table-frame">
              <table className="detail-table">
                <thead>
                  <tr>
                    <th>Catégorie</th>
                    <th>Nombre · unité</th>
                    <th>Taux</th>
                    <th>Publication</th>
                  </tr>
                </thead>
                <tbody>
                  {city.categories.map((category) => (
                    <tr key={category.code}>
                      <td>{category.label}</td>
                      <td>{formatInteger(category.incidentCount)} <span>{category.countUnit ?? "Unité inconnue"}</span></td>
                      <td>{formatCategoryRate(
                        category.ratePer1000,
                        category.rateDenominator,
                        category.populationDenominatorYear,
                        category.housingDenominatorYear
                      )}</td>
                      <td>
                        <span className={`publication-status status-${category.publicationStatus}`}>
                          {publicationLabel(category.publicationStatus)}
                        </span>
                        {category.exposureProvenance ? (
                          <small className="category-exposure-source">
                            {category.exposureScore === null
                              ? "Indice de catégorie indisponible"
                              : `Indice de catégorie ${formatComparativeIndex(category.exposureScore)}`}
                            {" · "}
                            {exposureComponentSourceLabel(
                              category.exposureProvenance,
                              category.exposureSourceYear,
                              city.year
                            )}
                          </small>
                        ) : null}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>

      <NearbyCitiesPanel
        originInseeCode={city.inseeCode}
        originName={city.name}
        originLatitude={city.latitude}
        originLongitude={city.longitude}
        year={city.year}
        categories={city.categories.map((category) => ({
          code: category.code,
          label: category.label
        }))}
      />
    </main>
  );
}

function comparisonScopeLabel(scope: "commune" | "department" | "region" | "france") {
  switch (scope) {
    case "commune": return "Commune";
    case "department": return "Département";
    case "region": return "Région";
    case "france": return "France";
  }
}

function comparisonBasis(denominator: "population" | "housing" | "unknown", years: number[]) {
  if (denominator === "unknown") return "Base inconnue";
  const base = denominator === "housing" ? "pour 1 000 logements" : "pour 1 000 habitants";
  return `${base} · Insee ${years.length ? years.join(", ") : "millésime inconnu"}`;
}

function publicationLabel(status: CityDetail["categories"][number]["publicationStatus"]) {
  switch (status) {
    case "published":
      return "Publié";
    case "masked":
      return "Masqué";
    case "unknown":
    default:
      return "Inconnu";
  }
}
