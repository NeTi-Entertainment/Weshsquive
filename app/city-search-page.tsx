"use client";

import Link from "next/link";
import dynamic from "next/dynamic";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";

import {
  buildCitySearchUrl,
  collectCategoryColumns,
  comparativeIndexProvenanceLabel,
  comparativeIndexComponentCountLabel,
  defaultSearchForm,
  describeComparativeIndex,
  findCategory,
  formatComparativeIndex,
  formatCoverage,
  formatCategoryRate,
  formatInteger,
  formatPopulation,
  formatComparativeIndexPopulationBand,
  getComparativeIndexClassName,
  getNextOffset,
  getPreviousOffset,
  getSortStateForColumn,
  describeBasketAvailability,
  updateSortForColumn,
  type CitySearchFormState,
  type CitySearchResult,
  type CitySearchSortBy
} from "@/client/city-search-ui";
import { LatestRequest } from "@/client/latest-request";
import type { NationalMapCriterion } from "@/client/france-map-ui";
import CityComparisonTable from "./city-comparison-table";

const FranceMap = dynamic(() => import("./france-map"), {
  ssr: false,
  loading: () => <div className="france-map-loading">Chargement de la carte…</div>
});

type CitySearchResponse = {
  count: number;
  results: CitySearchResult[];
};

type LoadState = "idle" | "loading" | "ready" | "error";

export default function CitySearchPage() {
  const [form, setForm] = useState<CitySearchFormState>(defaultSearchForm);
  const [submittedForm, setSubmittedForm] =
    useState<CitySearchFormState>(defaultSearchForm);
  const [results, setResults] = useState<CitySearchResult[]>([]);
  const [selectedCities, setSelectedCities] = useState<CitySearchResult[]>([]);
  const [comparisonOpen, setComparisonOpen] = useState(false);
  const [viewMode, setViewMode] = useState<"table" | "map">("table");
  const [mapCriterion, setMapCriterion] = useState<NationalMapCriterion>({ type: "comparativeIndex" });
  const [categoryOptions, setCategoryOptions] = useState<
    Array<{ code: string; label: string }>
  >([]);
  const [loadState, setLoadState] = useState<LoadState>("idle");
  const [errorMessage, setErrorMessage] = useState<string>("");
  const latestRequest = useRef(new LatestRequest());

  const categoryColumns = useMemo(() => collectCategoryColumns(results), [results]);
  const currentOffset = Number(submittedForm.offset || defaultSearchForm.offset);
  const currentLimit = Number(submittedForm.limit || defaultSearchForm.limit);

  useEffect(() => {
    if (selectedCities.length < 2) setComparisonOpen(false);
  }, [selectedCities.length]);

  async function loadCities(nextForm: CitySearchFormState) {
    const request = latestRequest.current.start();
    setLoadState("loading");
    setErrorMessage("");

    try {
      const response = await fetch(buildCitySearchUrl(nextForm), {
        headers: {
          accept: "application/json"
        },
        signal: request.signal
      });

      if (!response.ok) {
        throw new Error(`Erreur API ${response.status}`);
      }

      const data = (await response.json()) as CitySearchResponse;
      if (!request.isCurrent()) return;

      setResults(data.results);
      if (nextForm.year !== submittedForm.year) {
        setSelectedCities([]);
        setComparisonOpen(false);
      } else {
        setSelectedCities((selected) =>
          selected.map((city) =>
            data.results.find((result) => result.inseeCode === city.inseeCode) ?? city
          )
        );
      }
      setSubmittedForm(nextForm);
      setCategoryOptions((previousOptions) => {
        const byCode = new Map(previousOptions.map((option) => [option.code, option]));
        for (const category of collectCategoryColumns(data.results)) {
          byCode.set(category.code, {
            code: category.code,
            label: category.label
          });
        }
        return Array.from(byCode.values()).sort((left, right) =>
          left.label.localeCompare(right.label, "fr")
        );
      });
      setLoadState("ready");
    } catch (error) {
      if (!request.isCurrent()) return;

      setLoadState("error");
      setErrorMessage(error instanceof Error ? error.message : "Erreur inconnue");
    }
  }

  useEffect(() => {
    void loadCities(defaultSearchForm);

    return () => latestRequest.current.cancel();
  }, []);

  function updateField(field: keyof CitySearchFormState, value: string) {
    setForm((current) => ({
      ...current,
      [field]: value,
      offset: field === "offset" ? value : "0"
    }));
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void loadCities({
      ...form,
      offset: "0"
    });
  }

  function resetFilters() {
    setForm(defaultSearchForm);
    void loadCities(defaultSearchForm);
  }

  function goToOffset(offset: string) {
    const nextForm = {
      ...submittedForm,
      offset
    };
    setForm(nextForm);
    void loadCities(nextForm);
  }

  function sortByColumn(sortBy: CitySearchSortBy, sortCategoryCode = "") {
    const nextForm = updateSortForColumn(form, sortBy, sortCategoryCode);
    setForm(nextForm);
    void loadCities(nextForm);
  }

  function sortIndicator(sortBy: CitySearchSortBy, sortCategoryCode = "") {
    const sortState = getSortStateForColumn(submittedForm, sortBy, sortCategoryCode);

    if (!sortState.isActive) {
      return "";
    }

    return sortState.direction === "asc" ? "↑" : "↓";
  }

  function sortButtonClass(sortBy: CitySearchSortBy, sortCategoryCode = "") {
    const sortState = getSortStateForColumn(submittedForm, sortBy, sortCategoryCode);
    return sortState.isActive ? "sort-button active-sort" : "sort-button";
  }

  function toggleCityForComparison(city: CitySearchResult, checked: boolean) {
    setSelectedCities((current) =>
      checked
        ? current.some((selected) => selected.inseeCode === city.inseeCode)
          ? current
          : [...current, city]
        : current.filter((selected) => selected.inseeCode !== city.inseeCode)
    );
  }

  return (
    <main className="app-shell">
      <header className="top-bar">
        <div>
          <h1>Recherche communale</h1>
          <p>Données officielles importées en base locale</p>
        </div>
        <div className="status-strip">
          <span>Année {submittedForm.year}</span>
          <span>{results.length} lignes affichées</span>
        </div>
      </header>

      <form className="filter-panel" onSubmit={handleSubmit}>
        <label>
          Année
          <input
            type="number"
            min="2000"
            max="2100"
            value={form.year}
            onChange={(event) => updateField("year", event.target.value)}
            required
          />
        </label>

        <label>
          Région
          <input
            value={form.regionCode}
            onChange={(event) => updateField("regionCode", event.target.value)}
            placeholder="11"
          />
        </label>

        <label>
          Département
          <input
            value={form.departmentCode}
            onChange={(event) => updateField("departmentCode", event.target.value)}
            placeholder="95"
          />
        </label>

        <label className="wide-filter">
          Commune
          <input
            value={form.commune}
            onChange={(event) => updateField("commune", event.target.value)}
            placeholder="Seugy"
          />
        </label>

        <label>
          Population min.
          <input
            type="number"
            min="0"
            value={form.populationMin}
            onChange={(event) => updateField("populationMin", event.target.value)}
          />
        </label>

        <label>
          Population max.
          <input
            type="number"
            min="0"
            value={form.populationMax}
            onChange={(event) => updateField("populationMax", event.target.value)}
          />
        </label>

        <label>
          Indice min.
          <input
            type="number"
            min="0"
            max="100"
            value={form.comparativeIndexMin}
            onChange={(event) => updateField("comparativeIndexMin", event.target.value)}
          />
        </label>

        <label>
          Indice max.
          <input
            type="number"
            min="0"
            max="100"
            value={form.comparativeIndexMax}
            onChange={(event) => updateField("comparativeIndexMax", event.target.value)}
          />
        </label>

        <label className="wide-filter">
          Catégorie
          <select
            value={form.categoryCode}
            onChange={(event) => updateField("categoryCode", event.target.value)}
          >
            <option value="">Toutes</option>
            {categoryOptions.map((category) => (
              <option key={category.code} value={category.code}>
                {category.label}
              </option>
            ))}
          </select>
        </label>

        <label>
          Faits cat. min.
          <input
            type="number"
            min="0"
            value={form.categoryIncidentMin}
            onChange={(event) => updateField("categoryIncidentMin", event.target.value)}
            disabled={!form.categoryCode}
          />
        </label>

        <label>
          Faits cat. max.
          <input
            type="number"
            min="0"
            value={form.categoryIncidentMax}
            onChange={(event) => updateField("categoryIncidentMax", event.target.value)}
            disabled={!form.categoryCode}
          />
        </label>

        <label>
          Taux cat. min.
          <input
            type="number"
            min="0"
            step="0.01"
            value={form.categoryRateMin}
            onChange={(event) => updateField("categoryRateMin", event.target.value)}
            disabled={!form.categoryCode}
          />
        </label>

        <label>
          Taux cat. max.
          <input
            type="number"
            min="0"
            step="0.01"
            value={form.categoryRateMax}
            onChange={(event) => updateField("categoryRateMax", event.target.value)}
            disabled={!form.categoryCode}
          />
        </label>

        <label>
          Lignes
          <select value={form.limit} onChange={(event) => updateField("limit", event.target.value)}>
            <option value="25">25</option>
            <option value="50">50</option>
            <option value="100">100</option>
            <option value="200">200</option>
          </select>
        </label>

        <div className="filter-actions">
          <button type="submit" disabled={loadState === "loading"}>
            Rechercher
          </button>
          <button type="button" className="secondary-button" onClick={resetFilters}>
            Réinitialiser
          </button>
        </div>
      </form>

      <section className="results-toolbar">
        {viewMode === "table" ? (
          <div>
            <strong>{loadState === "loading" ? "Chargement" : `${results.length} communes sur cette page`}</strong>
            <span>{currentOffset + 1}-{currentOffset + results.length}</span>
            <span>Indice relatif calculé par l’application, fondé sur des percentiles par catégorie; ce n’est pas un total officiel.</span>
          </div>
        ) : (
          <div>
            <strong>Carte · filtres actifs</strong>
            <span>Les communes sont colorées par contour, à l’échelle adaptée au zoom et au champ visible.</span>
          </div>
        )}
        <div className="view-switch" role="group" aria-label="Mode d’affichage">
          <button
            type="button"
            className={viewMode === "table" ? "active-view" : ""}
            aria-pressed={viewMode === "table"}
            onClick={() => setViewMode("table")}
          >
            Tableau
          </button>
          <button
            type="button"
            className={viewMode === "map" ? "active-view" : ""}
            aria-pressed={viewMode === "map"}
            onClick={() => setViewMode("map")}
          >
            Carte
          </button>
        </div>
        {viewMode === "table" ? (
          <>
            <div className="color-legend" aria-label="Percentile de l'indice comparatif">
              <span className="stat-band-very-low">0-20</span>
              <span className="stat-band-low">20-40</span>
              <span className="stat-band-medium">40-60</span>
              <span className="stat-band-high">60-80</span>
              <span className="stat-band-very-high">80-95</span>
              <span className="stat-band-extreme">95-100</span>
            </div>
            <div className="comparison-actions">
              <span aria-live="polite">
                {`Sélection : ${selectedCities.length} commune${selectedCities.length === 1 ? "" : "s"}`}
              </span>
              <button
                type="button"
                disabled={selectedCities.length < 2}
                aria-expanded={comparisonOpen}
                aria-controls="city-comparison"
                onClick={() => setComparisonOpen((open) => !open)}
              >
                {comparisonOpen ? "Masquer" : "Comparer"}
              </button>
              {selectedCities.length > 0 ? (
                <button
                  type="button"
                  className="secondary-button"
                  onClick={() => {
                    setSelectedCities([]);
                    setComparisonOpen(false);
                  }}
                >
                  Effacer
                </button>
              ) : null}
            </div>
            <div className="pager">
              <button
                type="button"
                className="secondary-button"
                disabled={loadState === "loading" || currentOffset === 0}
                onClick={() => goToOffset(getPreviousOffset(submittedForm))}
              >
                Précédent
              </button>
              <button
                type="button"
                className="secondary-button"
                disabled={loadState === "loading" || results.length < currentLimit}
                onClick={() => goToOffset(getNextOffset(submittedForm))}
              >
                Suivant
              </button>
            </div>
          </>
        ) : null}
      </section>

      {loadState === "error" ? <p className="notice error">{errorMessage}</p> : null}
      {viewMode === "table" && loadState === "ready" && results.length === 0 ? (
        <p className="notice">Aucune commune ne correspond aux filtres.</p>
      ) : null}

      {viewMode === "table" && comparisonOpen && selectedCities.length >= 2 ? (
        <CityComparisonTable
          cities={selectedCities}
          year={submittedForm.year}
          categoryCode={submittedForm.categoryCode}
          onRemove={(inseeCode) => {
            setSelectedCities((current) => current.filter((city) => city.inseeCode !== inseeCode));
          }}
        />
      ) : null}

      {viewMode === "map" ? (
        <FranceMap
          form={submittedForm}
          categories={categoryOptions}
          criterion={mapCriterion}
          onCriterionChange={setMapCriterion}
        />
      ) : <div className="table-frame" aria-busy={loadState === "loading"}>
        <table>
          <thead>
            <tr>
              <th>
                <button
                  type="button"
                  className={sortButtonClass("name")}
                  onClick={() => sortByColumn("name")}
                  title="Trier par commune"
                >
                  Commune {sortIndicator("name")}
                </button>
              </th>
              <th>Département</th>
              <th>Région</th>
              <th>
                <button
                  type="button"
                  className={sortButtonClass("population")}
                  onClick={() => sortByColumn("population")}
                  title="Trier par population"
                >
                  Population {sortIndicator("population")}
                </button>
              </th>
              <th>Couverture</th>
              <th>
                <button
                  type="button"
                  className={sortButtonClass("comparativeIndex")}
                  onClick={() => sortByColumn("comparativeIndex")}
                  title="Trier par indice comparatif"
                >
                  Indice comparatif {sortIndicator("comparativeIndex")}
                </button>
              </th>
              {categoryColumns.map((category) => (
                <th key={category.code}>
                  <div className="category-sort-header">
                    <span>{category.label}</span>
                    <div>
                      <button
                        type="button"
                        className={sortButtonClass("categoryIncidentCount", category.code)}
                        onClick={() => sortByColumn("categoryIncidentCount", category.code)}
                        title={`Trier ${category.label} par nombre de faits`}
                      >
                        Faits {sortIndicator("categoryIncidentCount", category.code)}
                      </button>
                      <button
                        type="button"
                        className={sortButtonClass("categoryRatePer1000", category.code)}
                        onClick={() => sortByColumn("categoryRatePer1000", category.code)}
                        title={`Trier ${category.label} par taux publié, sur base documentée`}
                      >
                        Taux {sortIndicator("categoryRatePer1000", category.code)}
                      </button>
                    </div>
                  </div>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {results.map((result) => (
              <tr key={result.inseeCode}>
                <td>
                  <div className="city-row-heading">
                    <input
                      type="checkbox"
                      className="compare-checkbox"
                      checked={selectedCities.some((city) => city.inseeCode === result.inseeCode)}
                      onChange={(event) => toggleCityForComparison(result, event.target.checked)}
                      aria-label={`Comparer ${result.name}`}
                    />
                    <Link
                      className="city-link"
                      href={`/communes/${result.inseeCode}?year=${submittedForm.year}${submittedForm.categoryCode ? `&categoryCode=${encodeURIComponent(submittedForm.categoryCode)}` : ""}`}
                    >
                      {result.name}
                    </Link>
                  </div>
                  <span>{result.inseeCode}</span>
                </td>
                <td>
                  {result.departmentName}
                  <span>{result.departmentCode}</span>
                </td>
                <td>
                  {result.regionName}
                  <span>{result.regionCode}</span>
                </td>
                <td>
                  {formatPopulation(result.population)}
                  <span>{result.populationYear ?? ""}</span>
                </td>
                <td>
                  {formatCoverage(
                    result.published.publishedCategoryCount,
                    result.published.totalCategoryCount
                  )}
                </td>
                <td
                  className={getComparativeIndexClassName(result.comparativeIndex.value)}
                  title={`${describeComparativeIndex(result.comparativeIndex)} ${describeBasketAvailability(result.comparativeIndex.basketAvailability)}`}
                  aria-label={`Indice ${formatComparativeIndex(result.comparativeIndex.value)}. ${describeComparativeIndex(result.comparativeIndex)} ${describeBasketAvailability(result.comparativeIndex.basketAvailability)}`}
                >
                  <strong>{formatComparativeIndex(result.comparativeIndex.value)}</strong>
                  <span>{comparativeIndexProvenanceLabel(result.comparativeIndex.provenance)}</span>
                  <span>{comparativeIndexComponentCountLabel(result.comparativeIndex)}</span>
                  <span>
                    {formatComparativeIndexPopulationBand(result.comparativeIndex.populationBand)} · cohorte publiée minimale : {result.comparativeIndex.minimumReferenceCohortSize > 0 ? `${formatInteger(result.comparativeIndex.minimumReferenceCohortSize)} communes` : "indisponible"}
                  </span>
                </td>
                {categoryColumns.map((category) => {
                  const value = findCategory(result, category.code);
                  return (
                    <td
                      key={category.code}
                      className={value?.publicationStatus === "masked" ? "muted-cell" : ""}
                    >
                      {value ? (
                        <>
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
                        </>
                      ) : (
                        <span>Non disponible</span>
                      )}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>}

    </main>
  );
}
