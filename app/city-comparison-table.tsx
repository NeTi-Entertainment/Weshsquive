import Link from "next/link";

import {
  collectCategoryColumns,
  comparativeIndexComponentCountLabel,
  comparativeIndexProvenanceLabel,
  describeComparativeIndex,
  exposureComponentSourceLabel,
  findCategory,
  formatCategoryRate,
  formatComparativeIndex,
  formatCoverage,
  formatInteger,
  formatPopulation,
  getComparativeIndexClassName,
  type CitySearchResult
} from "@/client/city-search-ui";

type CityComparisonTableProps = {
  cities: CitySearchResult[];
  year: string;
  categoryCode: string;
  onRemove: (inseeCode: string) => void;
};

export default function CityComparisonTable({
  cities,
  year,
  categoryCode,
  onRemove
}: CityComparisonTableProps) {
  const categories = collectCategoryColumns(cities);

  return (
    <section
      id="city-comparison"
      className="comparison-section"
      aria-labelledby="city-comparison-title"
    >
      <header className="comparison-heading">
        <div>
          <h2 id="city-comparison-title">Comparaison des communes</h2>
          <p>
            Année {year} · indice d’exposition à échelle fixe · catégories comparées séparément, sans somme d’unités différentes
          </p>
        </div>
        <span>{cities.length} communes</span>
      </header>

      <div className="comparison-table-frame">
        <table className="comparison-table">
          <thead>
            <tr>
              <th scope="col">Indicateur</th>
              {cities.map((city) => (
                <th scope="col" key={city.inseeCode}>
                  <div className="comparison-city-header">
                    <Link
                      className="city-link"
                      href={`/communes/${city.inseeCode}?year=${year}${categoryCode ? `&categoryCode=${encodeURIComponent(categoryCode)}` : ""}`}
                    >
                      {city.name}
                    </Link>
                    <span>{city.inseeCode} · {city.departmentName}</span>
                    <button
                      type="button"
                      className="comparison-remove secondary-button"
                      onClick={() => onRemove(city.inseeCode)}
                      aria-label={`Retirer ${city.name} de la comparaison`}
                    >
                      Retirer
                    </button>
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Population</th>
              {cities.map((city) => (
                <td key={city.inseeCode}>
                  <strong>{formatPopulation(city.population)}</strong>
                  <span>{city.populationYear === null ? "Millésime inconnu" : `Insee ${city.populationYear}`}</span>
                </td>
              ))}
            </tr>
            <tr>
              <th scope="row">Couverture</th>
              {cities.map((city) => (
                <td key={city.inseeCode}>
                  {formatCoverage(
                    city.published.publishedCategoryCount,
                    city.published.totalCategoryCount
                  )}
                </td>
              ))}
            </tr>
            <tr>
              <th scope="row">Indice d’exposition</th>
              {cities.map((city) => (
                <td
                  key={city.inseeCode}
                  className={getComparativeIndexClassName(city.comparativeIndex.value)}
                  title={describeComparativeIndex(city.comparativeIndex)}
                >
                  <strong>{formatComparativeIndex(city.comparativeIndex.value)}</strong>
                  <span>{comparativeIndexProvenanceLabel(city.comparativeIndex.provenance, Number(year))}</span>
                  <span>{comparativeIndexComponentCountLabel(city.comparativeIndex)}</span>
                  {city.comparativeIndex.lowVolumeCapApplied ? <span>Plafond faible volume appliqué</span> : null}
                </td>
              ))}
            </tr>
            {categories.map((category) => (
              <tr key={category.code}>
                <th scope="row">{category.label}</th>
                {cities.map((city) => {
                  const value = findCategory(city, category.code);

                  if (!value) {
                    return <td key={city.inseeCode}><span>Non disponible</span></td>;
                  }

                  if (value.publicationStatus === "masked") {
                    return <td
                      className="muted-cell"
                      key={city.inseeCode}
                      title={exposureComponentSourceLabel(
                        value.exposureProvenance,
                        value.exposureSourceYear,
                        Number(year)
                      ) ?? undefined}
                    ><strong>Masqué</strong><span>Valeur non publiée</span></td>;
                  }

                  if (value.publicationStatus === "unknown") {
                    return <td
                      className="muted-cell"
                      key={city.inseeCode}
                      title={exposureComponentSourceLabel(
                        value.exposureProvenance,
                        value.exposureSourceYear,
                        Number(year)
                      ) ?? undefined}
                    ><strong>Non renseigné</strong><span>Statut de publication inconnu</span></td>;
                  }

                  return (
                    <td
                      key={city.inseeCode}
                      title={exposureComponentSourceLabel(
                        value.exposureProvenance,
                        value.exposureSourceYear,
                        Number(year)
                      ) ?? undefined}
                    >
                      <strong>{formatInteger(value.incidentCount)}</strong>
                      <span>{value.countUnit ?? "Unité inconnue"}</span>
                      <span>
                        {formatCategoryRate(
                          value.ratePer1000,
                          value.rateDenominator,
                          value.populationDenominatorYear,
                          value.housingDenominatorYear
                        )}
                      </span>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
