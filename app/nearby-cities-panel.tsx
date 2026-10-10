"use client";

import Link from "next/link";
import dynamic from "next/dynamic";
import { FormEvent, useEffect, useRef, useState } from "react";

import {
  buildNearbySearchUrl,
  createDefaultNearbySearchForm,
  defaultNearbySearchForm,
  formatDistance,
  getNearbyMapCriterion,
  selectNearbyMapCriterion,
  type NearbyCityResult,
  type NearbySearchFormState
} from "@/client/nearby-cities-ui";
import {
  comparativeIndexProvenanceLegend,
  getComparativeIndexVisualStyle,
  type NearbyMapPoint
} from "@/client/nearby-map-ui";
import {
  comparativeIndexComponentCountLabel,
  comparativeIndexProvenanceLabel,
  describeComparativeIndex,
  describeBasketAvailability,
  formatInteger,
  formatPopulation,
  formatCategoryRate,
  formatComparativeIndex,
  formatCoverage,
  getComparativeIndexClassName
} from "@/client/city-search-ui";
import { isExposureIndexCategory } from "@/shared/exposure-index";
import { LatestRequest } from "@/client/latest-request";

type NearbyCitiesPanelProps = {
  originInseeCode: string;
  originName: string;
  originLatitude: number | null;
  originLongitude: number | null;
  year: number;
  categories: Array<{ code: string; label: string }>;
};

type NearbySearchResponse = {
  totalCount: number;
  results: NearbyCityResult[];
  mapPoints: NearbyMapPoint[];
};

type LoadState = "loading" | "ready" | "error";

const radiusOptions = [25, 50, 100, 200] as const;
const NearbyCitiesMap = dynamic(() => import("./nearby-cities-map"), {
  ssr: false,
  loading: () => <div className="nearby-map-loading">Chargement de la carte…</div>
});

export default function NearbyCitiesPanel({
  originInseeCode,
  originName,
  originLatitude,
  originLongitude,
  year,
  categories
}: NearbyCitiesPanelProps) {
  const [form, setForm] = useState<NearbySearchFormState>(createDefaultNearbySearchForm);
  const [submittedForm, setSubmittedForm] =
    useState<NearbySearchFormState>(createDefaultNearbySearchForm);
  const [results, setResults] = useState<NearbyCityResult[]>([]);
  const [mapPoints, setMapPoints] = useState<NearbyMapPoint[]>([]);
  const [totalCount, setTotalCount] = useState(0);
  const [loadState, setLoadState] = useState<LoadState>("loading");
  const [errorMessage, setErrorMessage] = useState("");
  const latestRequest = useRef(new LatestRequest());

  async function loadNearby(nextForm: NearbySearchFormState) {
    const request = latestRequest.current.start();
    setLoadState("loading");
    setErrorMessage("");

    try {
      const response = await fetch(buildNearbySearchUrl(originInseeCode, year, nextForm), {
        headers: { accept: "application/json" },
        signal: request.signal
      });

      if (!response.ok) {
        throw new Error(`Erreur API ${response.status}`);
      }

      const data = (await response.json()) as NearbySearchResponse;
      if (!request.isCurrent()) return;

      setResults(data.results);
      setMapPoints(data.mapPoints);
      setTotalCount(data.totalCount);
      setSubmittedForm(nextForm);
      setLoadState("ready");
    } catch (error) {
      if (!request.isCurrent()) return;

      setLoadState("error");
      setErrorMessage(error instanceof Error ? error.message : "Erreur inconnue");
    }
  }

  useEffect(() => {
    const resetForm = createDefaultNearbySearchForm();
    setForm(resetForm);
    setSubmittedForm(resetForm);
    setResults([]);
    setMapPoints([]);
    setTotalCount(0);
    void loadNearby(resetForm);

    return () => latestRequest.current.cancel();
  }, [originInseeCode, year]);

  function updateField(field: keyof NearbySearchFormState, value: string) {
    setForm((current) => ({ ...current, [field]: value, offset: "0" }));
  }

  function selectRadius(radiusKm: number) {
    const nextForm = { ...form, radiusKm: String(radiusKm), offset: "0" };
    setForm(nextForm);
    void loadNearby(nextForm);
  }

  function selectMapCriterion(value: string) {
    const environmentalRadius = radiusOptions.find(
      (radiusKm) => value === `environmental:${radiusKm}`
    );
    const nextForm = environmentalRadius !== undefined
      ? selectNearbyMapCriterion(form, {
          type: "environmentalRisk",
          radiusKm: environmentalRadius
        })
      : selectNearbyMapCriterion(
          form,
          value ? { type: "categoryRate" } : { type: "comparativeIndex" },
          value
        );
    setForm(nextForm);
    void loadNearby(nextForm);
  }

  function submitFilters(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const nextForm = { ...form, offset: "0" };
    setForm(nextForm);
    void loadNearby(nextForm);
  }

  function resetFilters() {
    const resetForm = createDefaultNearbySearchForm();
    setForm(resetForm);
    void loadNearby(resetForm);
  }

  function goToOffset(offset: number) {
    const nextForm = { ...submittedForm, offset: String(Math.max(0, offset)) };
    setForm(nextForm);
    void loadNearby(nextForm);
  }

  const currentOffset = Number(submittedForm.offset);
  const currentLimit = Number(submittedForm.limit);
  const selectedCategory = categories.find(
    (category) => category.code === submittedForm.categoryCode
  );
  const selectedMapCategory = categories.find(
    (category) => category.code === submittedForm.mapCategoryCode
  );
  const mapCriterion = getNearbyMapCriterion(submittedForm);
  const mapSelectionValue = submittedForm.mapEnvironmentalRadiusKm
    ? `environmental:${submittedForm.mapEnvironmentalRadiusKm}`
    : submittedForm.mapCategoryCode;

  return (
    <section className="nearby-section" aria-labelledby="nearby-title">
      <div className="nearby-heading">
        <div>
          <h2 id="nearby-title">Communes à proximité</h2>
          <p>
            Depuis {originName}, année {year}
          </p>
        </div>
        <strong>{loadState === "loading" ? "Chargement" : `${totalCount} communes`}</strong>
      </div>

      <div className="radius-control" aria-label="Rayon de recherche">
        {radiusOptions.map((radiusKm) => (
          <button
            key={radiusKm}
            type="button"
            className={form.radiusKm === String(radiusKm) ? "active-radius" : ""}
            onClick={() => selectRadius(radiusKm)}
            disabled={loadState === "loading"}
          >
            {radiusKm} km
          </button>
        ))}
      </div>

      <form className="nearby-filter-panel" onSubmit={submitFilters}>
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
        <label className="nearby-category-filter">
          Catégorie
          <select
            value={form.categoryCode}
            onChange={(event) => updateField("categoryCode", event.target.value)}
          >
            <option value="">Toutes</option>
            {categories.map((category) => (
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
        <div className="nearby-filter-actions">
          <button type="submit" disabled={loadState === "loading"}>
            Filtrer
          </button>
          <button type="button" className="secondary-button" onClick={resetFilters}>
            Réinitialiser
          </button>
        </div>
      </form>

      <div className="nearby-toolbar">
        <span>Indice d’exposition calculé par l’application; ce n’est pas une statistique officielle.</span>
        <div className="pager">
          <button
            type="button"
            className="secondary-button"
            disabled={loadState === "loading" || currentOffset === 0}
            onClick={() => goToOffset(currentOffset - currentLimit)}
          >
            Précédent
          </button>
          <button
            type="button"
            className="secondary-button"
            disabled={
              loadState === "loading" || currentOffset + results.length >= totalCount
            }
            onClick={() => goToOffset(currentOffset + currentLimit)}
          >
            Suivant
          </button>
        </div>
      </div>

      <section className="nearby-map-section" aria-labelledby="nearby-map-title">
        <div className="nearby-map-header">
          <div>
            <h3 id="nearby-map-title">Carte des communes voisines</h3>
            <p>
              Distances à vol d’oiseau entre centres communaux. Les valeurs indisponibles restent grises.
            </p>
          </div>
          <label>
            Critère de couleur
            <select
              value={mapSelectionValue}
              onChange={(event) => selectMapCriterion(event.target.value)}
              disabled={loadState === "loading"}
            >
              <option value="">Indice d’exposition</option>
              <optgroup label="Taux par catégorie">
                {categories.map((category) => (
                  <option key={category.code} value={category.code}>{category.label}</option>
                ))}
              </optgroup>
              <optgroup label="Indice environnemental">
                {radiusOptions.map((radiusKm) => (
                  <option key={radiusKm} value={`environmental:${radiusKm}`}>
                    Environnement {radiusKm} km
                  </option>
                ))}
              </optgroup>
            </select>
          </label>
        </div>
        <div className="nearby-map-legend" aria-label="Légende de la carte">
          {mapCriterion.type === "categoryRate" && selectedMapCategory && !isExposureIndexCategory(selectedMapCategory.code) ? (
            <>
              <span className="stat-band-very-low">0–20</span>
              <span className="stat-band-low">20–40</span>
              <span className="stat-band-medium">40–60</span>
              <span className="stat-band-high">60–80</span>
              <span className="stat-band-very-high">80–95</span>
              <span className="stat-band-extreme">95–100</span>
            </>
          ) : (
            <>
              <span className="stat-band-very-low">0–10 Très faible</span>
              <span className="stat-band-low">&gt;10–35 Faible</span>
              <span className="stat-band-medium">&gt;35–50 Modérée</span>
              <span className="stat-band-high">&gt;50–65 Élevée</span>
              <span className="stat-band-very-high">&gt;65–85 Très élevée</span>
              <span className="stat-band-extreme">&gt;85–100 Extrême</span>
            </>
          )}
          {mapCriterion.type !== "comparativeIndex" ? (
            <span className="map-band-unavailable">Non disponible</span>
          ) : null}
          {mapCriterion.type === "comparativeIndex" ? (
            <div className="comparative-provenance-legend" aria-label="Provenance de l’indice d’exposition">
              {comparativeIndexProvenanceLegend.map((provenance) => {
                const visualStyle = getComparativeIndexVisualStyle(
                  provenance === "unavailable" ? null : 50,
                  provenance
                );
                return (
                  <span className="comparative-provenance-key" key={provenance}>
                    <i
                      aria-hidden="true"
                      className="comparative-provenance-swatch"
                      style={{
                        backgroundColor: visualStyle.fillColor,
                        opacity: visualStyle.fillOpacity,
                        borderColor: `rgba(38, 54, 70, ${visualStyle.borderOpacity})`,
                        borderStyle: visualStyle.dashArray ? "dashed" : "solid",
                        borderWidth: visualStyle.borderWeight
                      }}
                    />
                    {comparativeIndexProvenanceLabel(provenance)}
                  </span>
                );
              })}
            </div>
          ) : null}
        </div>
        <p className="nearby-map-method">
          {mapCriterion.type === "environmentalRisk"
            ? `Indice environnemental calculé par l’application : moyenne pondérée des indices d’exposition des communes voisines dans un rayon de ${mapCriterion.radiusKm} km. Ce n’est ni une statistique officielle, ni un percentile environnemental, ni une mesure du risque individuel.`
            : selectedMapCategory
              ? isExposureIndexCategory(selectedMapCategory.code)
                ? `Couleur sur l’échelle fixe de risque, calculée depuis le taux communal publié de ${selectedMapCategory.label}; les compléments estimatifs ne colorent pas ce calque.`
                : `Percentile national du taux publié pour ${selectedMapCategory.label}, à année, unité, base et tranche de population comparables.`
              : "Indice d’exposition calculé par l’application : moyenne à poids égal des scores fixes de taux par catégorie. Les compléments départementaux ne remplacent jamais les valeurs communales masquées."}
        </p>
        <p className="nearby-map-method">
          Carte de points communaux : elle ne colore ni les contours des communes ni une surface continue.
        </p>
        {originLatitude !== null && originLongitude !== null ? (
          <NearbyCitiesMap
            origin={{
              inseeCode: originInseeCode,
              name: originName,
              latitude: originLatitude,
              longitude: originLongitude
            }}
            year={year}
            points={mapPoints}
            criterion={mapCriterion}
          />
        ) : (
          <p className="nearby-notice">Carte indisponible : coordonnées de la commune inconnues.</p>
        )}
      </section>

      {loadState === "error" ? <p className="nearby-notice error">{errorMessage}</p> : null}
      {loadState === "ready" && results.length === 0 ? (
        <p className="nearby-notice">Aucune commune ne correspond aux filtres.</p>
      ) : null}

      <div className="nearby-table-frame" aria-busy={loadState === "loading"}>
        <table className="nearby-table">
          <thead>
            <tr>
              <th>Commune</th>
              <th>Distance</th>
              <th>Département</th>
              <th>Population</th>
              <th>Couverture</th>
              <th>Indice d’exposition</th>
              {selectedCategory ? <th>{selectedCategory.label}</th> : null}
            </tr>
          </thead>
          <tbody>
            {results.map((result) => (
              <tr key={result.inseeCode}>
                <td>
                  <Link
                    className="city-link"
                    href={`/communes/${result.inseeCode}?year=${year}${submittedForm.categoryCode ? `&categoryCode=${encodeURIComponent(submittedForm.categoryCode)}` : ""}`}
                  >
                    {result.name}
                  </Link>
                  <span>{result.inseeCode}</span>
                </td>
                <td>{formatDistance(result.distanceKm)}</td>
                <td>
                  {result.departmentName}
                  <span>{result.departmentCode}</span>
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
                    {result.comparativeIndex.lowVolumeCapApplied ? "Plafond faible volume appliqué" : "Échelle fixe calibrée sur les taux 2025"}
                  </span>
                </td>
                {selectedCategory ? (
                  <td>
                    <strong>
                      {formatInteger(result.selectedCategory?.incidentCount ?? null)}
                    </strong>
                    <span>{result.selectedCategory?.countUnit ?? "Unité inconnue"}</span>
                    <span>
                      {result.selectedCategory
                        ? formatCategoryRate(
                            result.selectedCategory.ratePer1000,
                            result.selectedCategory.rateDenominator,
                            result.selectedCategory.populationDenominatorYear,
                            result.selectedCategory.housingDenominatorYear
                          )
                        : "Non publié"}
                    </span>
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  );
}
