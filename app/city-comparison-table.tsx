import Link from "next/link";

import {
  collectCategoryColumns,
  comparativeIndexCompletenessLabel,
  comparativeIndexStatusLabel,
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

function formatPopulationBand(band: string | null): string {
  switch (band) {
    case "under-1000":
      return "Moins de 1 000 habitants";
    case "1000-4999":
      return "1 000 à 4 999 habitants";
    case "5000-9999":
      return "5 000 à 9 999 habitants";
    case "10000-49999":
      return "10 000 à 49 999 habitants";
    case "50000-99999":
      return "50 000 à 99 999 habitants";
    case "100000-plus":
      return "100 000 habitants et plus";
    default:
      return "Tranche inconnue";
  }
}

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
            Année {year} · indices à comparer uniquement dans une même tranche de population · aucune somme multi-catégories
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
              <th scope="row">Indice comparatif</th>
              {cities.map((city) => (
                <td
                  key={city.inseeCode}
                  className={getComparativeIndexClassName(city.comparativeIndex.value)}
                  title={`${comparativeIndexStatusLabel(city.comparativeIndex.status)} · tranche ${city.comparativeIndex.populationBand ?? "inconnue"} · ${city.comparativeIndex.publishedBasketCategoryCount}/${city.comparativeIndex.basketCategoryCount} indicateurs`}
                >
                  <strong>{formatComparativeIndex(city.comparativeIndex.value)}</strong>
                  <span>
                    {city.comparativeIndex.completeness
                      ? comparativeIndexCompletenessLabel(city.comparativeIndex.completeness)
                      : comparativeIndexStatusLabel(city.comparativeIndex.status)}
                  </span>
                  <span>{formatPopulationBand(city.comparativeIndex.populationBand)}</span>
                  <span>{city.comparativeIndex.cohortSize.toLocaleString("fr-FR")} communes comparables</span>
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
                    return <td className="muted-cell" key={city.inseeCode}><strong>Masqué</strong><span>Valeur non publiée</span></td>;
                  }

                  if (value.publicationStatus === "unknown") {
                    return <td className="muted-cell" key={city.inseeCode}><strong>Non renseigné</strong><span>Statut de publication inconnu</span></td>;
                  }

                  return (
                    <td key={city.inseeCode}>
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
