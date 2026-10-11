"use client";

import Link from "next/link";
import { type ReactNode, useCallback, useEffect, useRef, useState } from "react";
import { CircleMarker, MapContainer, Polygon, Popup, TileLayer, Tooltip, useMap, useMapEvents } from "react-leaflet";
import L from "leaflet";

import {
  comparativeIndexComponentCountLabel,
  comparativeIndexProvenanceLabel,
  describeComparativeIndex,
  formatCategoryRate,
  formatComparativeIndex,
  formatInteger,
  formatPopulation
} from "@/client/city-search-ui";
import { LatestRequest } from "@/client/latest-request";
import {
  formatEnvironmentalRiskCoverage,
  formatEnvironmentalRiskProvenance,
  formatEnvironmentalRiskStatus,
  formatEnvironmentalRiskValue
} from "@/client/environmental-risk-ui";
import {
  comparativeIndexProvenanceLegend,
  formatEnvironmentalRiskNeighborProvenance,
  getComparativeIndexVisualStyle
} from "@/client/nearby-map-ui";
import {
  formatPropertyMarketInterval,
  formatPropertyMarketValue,
  PROPERTY_MARKET_LEGEND_BANDS,
  propertyMarketSourceLabel,
  propertyMarketStatusLabel,
  propertyTypeLabel
} from "@/client/property-market-ui";
import { isExposureIndexCategory } from "@/shared/exposure-index";
import {
  buildNationalMapUrl,
  formatNationalMapResultCount,
  getNationalMapFeatureColor,
  getNationalMapFeatureVisualStyle,
  multiPolygonToLeafletPositions,
  NATIONAL_MAP_GROUP_COLOR,
  type NationalMapBounds,
  type NationalMapCriterion
} from "@/client/france-map-ui";
import type { CitySearchFormState } from "@/client/city-search-ui";
import type { NationalMapCommune, NationalMapGroup, NationalMapPoint, NationalMapResult } from "@/server/national-map";
import type { RentPropertyType, SalePropertyType } from "@/shared/property-market";

type FranceMapProps = {
  form: CitySearchFormState;
  categories: Array<{ code: string; label: string }>;
  criterion: NationalMapCriterion;
  onCriterionChange(criterion: NationalMapCriterion): void;
  optionsOpen: boolean;
  filtersPanel: ReactNode;
  searchError: string;
};

type MapLoadState = "loading" | "ready" | "error";

export default function FranceMap({
  form,
  categories,
  criterion,
  onCriterionChange,
  optionsOpen,
  filtersPanel,
  searchError
}: FranceMapProps) {
  const [result, setResult] = useState<NationalMapResult | null>(null);
  const [loadState, setLoadState] = useState<MapLoadState>("loading");
  const [error, setError] = useState("");
  const handleResult = useCallback((nextResult: NationalMapResult) => {
    setResult(nextResult);
    setLoadState("ready");
    setError("");
  }, []);
  const handleLoading = useCallback(() => {
    setResult(null);
    setLoadState("loading");
    setError("");
  }, []);
  const handleError = useCallback((message: string) => {
    setLoadState("error");
    setError(message);
  }, []);

  function changeCriterion(type: string) {
    if (type === "comparativeIndex") {
      onCriterionChange({ type });
    } else if (type === "categoryRate") {
      const categoryCode = criterion.type === "categoryRate"
        ? criterion.categoryCode
        : categories[0]?.code;
      if (categoryCode) onCriterionChange({ type, categoryCode });
    } else if (type === "environmentalRisk") {
      onCriterionChange({
        type: "environmentalRisk",
        radiusKm: criterion.type === "environmentalRisk" ? criterion.radiusKm : 25
      });
    } else if (type === "salePrice") {
      onCriterionChange({
        type: "salePrice",
        propertyType: criterion.type === "salePrice" ? criterion.propertyType : "all"
      });
    } else if (type === "rentPrice") {
      onCriterionChange({
        type: "rentPrice",
        propertyType: criterion.type === "rentPrice" ? criterion.propertyType : "apartment"
      });
    }
  }

  function changeCategory(categoryCode: string) {
    if (categoryCode) onCriterionChange({ type: "categoryRate", categoryCode });
  }

  function changeRadius(radiusKm: string) {
    const radius = Number(radiusKm);
    if ([25, 50, 100, 200].includes(radius)) {
      onCriterionChange({ type: "environmentalRisk", radiusKm: radius as 25 | 50 | 100 | 200 });
    }
  }

  function changeMarketPropertyType(propertyType: string) {
    if (
      criterion.type === "salePrice"
      && ["all", "apartment", "house"].includes(propertyType)
    ) {
      onCriterionChange({ type: "salePrice", propertyType: propertyType as SalePropertyType });
    } else if (
      criterion.type === "rentPrice"
      && ["apartment", "house"].includes(propertyType)
    ) {
      onCriterionChange({ type: "rentPrice", propertyType: propertyType as RentPropertyType });
    }
  }

  const propertyLayerActive = criterion.type === "salePrice" || criterion.type === "rentPrice";

  return (
    <section className="france-map-section" aria-label="Carte de France des communes">
      <aside
        id="map-options-panel"
        className="france-map-options-panel"
        aria-label="Options de la carte"
        hidden={!optionsOpen}
      >
        <header className="france-map-options-header">
          <h2>Options de la carte</h2>
          <p>Régions, départements, puis communes visibles dans le champ de la carte.</p>
        </header>
        {filtersPanel}
        <div className="france-map-options-content">
          <div className="france-map-controls">
            <label>
              Indicateur
              <select value={criterion.type} onChange={(event) => changeCriterion(event.target.value)}>
                <option value="comparativeIndex">Indice d’exposition</option>
                <option value="categoryRate" disabled={categories.length === 0}>Taux par catégorie</option>
                <option value="environmentalRisk">Indice environnemental</option>
                <option value="salePrice">Prix d’achat médian</option>
                <option value="rentPrice">Loyer d’annonce estimé</option>
              </select>
            </label>
            {criterion.type === "categoryRate" ? (
              <label>
                Catégorie
                <select value={criterion.categoryCode} onChange={(event) => changeCategory(event.target.value)}>
                  {categories.map((category) => (
                    <option key={category.code} value={category.code}>{category.label}</option>
                  ))}
                </select>
              </label>
            ) : null}
            {criterion.type === "environmentalRisk" ? (
              <label>
                Rayon environnemental
                <select value={criterion.radiusKm} onChange={(event) => changeRadius(event.target.value)}>
                  {[25, 50, 100, 200].map((radius) => (
                    <option key={radius} value={radius}>{radius} km</option>
                  ))}
                </select>
              </label>
            ) : null}
            {propertyLayerActive ? (
              <label>
                Type de logement
                <select value={criterion.propertyType} onChange={(event) => changeMarketPropertyType(event.target.value)}>
                  {criterion.type === "salePrice" ? <option value="all">Tous logements</option> : null}
                  <option value="apartment">Appartements</option>
                  <option value="house">Maisons</option>
                </select>
              </label>
            ) : null}
          </div>

          <div className="france-map-legend" aria-label="Légende de la carte">
            <LegendSwatches
              propertyMarket={propertyLayerActive}
              absoluteScale={criterion.type === "comparativeIndex" || criterion.type === "environmentalRisk" ||
                (criterion.type === "categoryRate" && isExposureIndexCategory(criterion.categoryCode))}
            />
            {criterion.type !== "comparativeIndex" ? (
              <span className="map-band-unavailable">
                {criterion.type === "environmentalRisk"
                  ? "Pas assez de données"
                  : propertyLayerActive
                    ? "Donnée non affichable"
                    : "Non disponible"}
              </span>
            ) : null}
            {criterion.type === "environmentalRisk" ? (
              <span>La couleur reflète la moyenne pondérée par la distance des indices d’exposition des communes voisines.</span>
            ) : null}
            {criterion.type === "comparativeIndex" ? (
              <span>Indice d’exposition calculé par l’application, normalisé par catégorie sur l’échelle fixe calibrée en 2025.</span>
            ) : null}
            {criterion.type === "categoryRate" ? (
              <span>{isExposureIndexCategory(criterion.categoryCode)
                ? "Couleur : score fixe calculé depuis le taux communal publié; les valeurs masquées restent grises."
                : "Couleur : percentile national du taux publié pour la même année, unité et base."}</span>
            ) : null}
            {propertyLayerActive ? (
              <span>Couleur : percentile national des communes publiables pour la même année et le même type de logement.</span>
            ) : null}
            {criterion.type === "comparativeIndex" ? (
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
                <span className="comparative-provenance-note">
                  Les estimations utilisent les compléments départementaux SSMSI uniquement lorsque la valeur communale est masquée.
                </span>
              </div>
            ) : null}
          </div>

          {criterion.type === "environmentalRisk" && result?.level !== "commune" ? (
            <p className="france-map-note">Zoomez jusqu’aux communes pour afficher l’indicateur environnemental.</p>
          ) : null}
          {propertyLayerActive && result?.level !== "commune" ? (
            <p className="france-map-note">Zoomez jusqu’aux communes pour afficher les données immobilières.</p>
          ) : null}
          {propertyLayerActive ? (
            <p className="france-map-note">
              Les prix d’achat sont des médianes calculées à partir de DVF. Les loyers sont des estimations d’annonces non meublées, charges comprises, publiées par l’ANIL.
            </p>
          ) : null}
        </div>
      </aside>

      <div className="france-map-status" aria-live="polite">
        {searchError ? <p className="error">Recherche : {searchError}</p> : null}
        {loadState === "error" ? <p className="error">Carte : {error}</p> : null}
        {loadState === "loading" ? <p>Actualisation de la carte…</p> : null}
        {loadState === "ready" && result ? <p>{formatNationalMapResultCount(result)}</p> : null}
        {loadState === "ready" && result?.level === "commune" && !result.requiresZoom && result.communes.length === 0 ? (
          <p>Aucune commune avec contour géographique ne correspond à cette emprise et à ces filtres.</p>
        ) : null}
        {loadState === "ready" && result && result.level !== "commune" && result.groups.length === 0 ? (
          <p>Aucun repère administratif avec coordonnées ne correspond à cette emprise.</p>
        ) : null}
      </div>

      <MapContainer
        className="france-map-canvas"
        center={[46.55, 2.45]}
        zoom={5}
        minZoom={4}
        maxZoom={18}
        preferCanvas
        scrollWheelZoom
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <MapViewportLoader
          form={form}
          criterion={criterion}
          onResult={handleResult}
          onLoading={handleLoading}
          onError={handleError}
        />
        {result ? <SelectedTerritoryFit result={result} regionCode={form.regionCode} departmentCode={form.departmentCode} /> : null}
        {result?.level === "region" || result?.level === "department" ? (
          <GroupMarkers groups={result.groups} />
        ) : null}
        {result?.level === "commune" ? (
          <CommunePolygons communes={result.communes} year={Number(form.year)} criterion={criterion} />
        ) : null}
      </MapContainer>
    </section>
  );
}

function LegendSwatches({ propertyMarket, absoluteScale }: { propertyMarket: boolean; absoluteScale: boolean }) {
  if (propertyMarket) {
    return PROPERTY_MARKET_LEGEND_BANDS.map((band) => (
      <span key={band.className} className={band.className}>{band.label}</span>
    ));
  }
  const bands = absoluteScale
    ? [
        ["stat-band-very-low", "0–10 Très faible"],
        ["stat-band-low", ">10–35 Faible"],
        ["stat-band-medium", ">35–50 Modérée"],
        ["stat-band-high", ">50–65 Élevée"],
        ["stat-band-very-high", ">65–85 Très élevée"],
        ["stat-band-extreme", ">85–100 Extrême"]
      ]
    : [
        ["stat-band-very-low", "0–20"],
        ["stat-band-low", "20–40"],
        ["stat-band-medium", "40–60"],
        ["stat-band-high", "60–80"],
        ["stat-band-very-high", "80–95"],
        ["stat-band-extreme", "95–100"]
      ];
  return bands.map(([className, label]) => (
    <span key={className} className={className}>{label}</span>
  ));
}

function MapViewportLoader({
  form,
  criterion,
  onResult,
  onLoading,
  onError
}: {
  form: CitySearchFormState;
  criterion: NationalMapCriterion;
  onResult(result: NationalMapResult): void;
  onLoading(): void;
  onError(message: string): void;
}) {
  const map = useMap();
  const latestRequest = useRef(new LatestRequest());
  const debounceTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const territoryKey = `${form.regionCode}:${form.departmentCode}`;
  const previousTerritory = useRef(territoryKey);
  const pendingFocusZoom = useRef<number | null>(
    form.departmentCode ? 7 : form.regionCode ? 5 : null
  );

  const loadViewport = useCallback(async () => {
    const bounds = map.getBounds();
    const mapBounds: NationalMapBounds = {
      west: bounds.getWest(),
      south: bounds.getSouth(),
      east: bounds.getEast(),
      north: bounds.getNorth()
    };
    const request = latestRequest.current.start();
    const requestedZoom = pendingFocusZoom.current ?? map.getZoom();
    try {
      const response = await fetch(buildNationalMapUrl(form, mapBounds, requestedZoom, criterion), {
        headers: { accept: "application/json" },
        signal: request.signal
      });
      if (!response.ok) throw new Error(`Erreur API ${response.status}`);
      const payload = await response.json() as NationalMapResult;
      if (request.isCurrent()) {
        if (
          (requestedZoom === 5 && payload.level === "region") ||
          (requestedZoom === 7 && payload.level === "department")
        ) {
          pendingFocusZoom.current = null;
        }
        onResult(payload);
      }
    } catch (caught) {
      if (!request.isCurrent()) return;
      onError(caught instanceof Error ? caught.message : "Erreur inconnue");
    }
  }, [criterion, form, map, onError, onResult]);

  useEffect(() => {
    if (previousTerritory.current === territoryKey) return;
    previousTerritory.current = territoryKey;
    pendingFocusZoom.current = form.departmentCode ? 7 : form.regionCode ? 5 : null;
  }, [form.departmentCode, form.regionCode, territoryKey]);

  const scheduleLoad = useCallback(() => {
    if (debounceTimer.current) clearTimeout(debounceTimer.current);
    latestRequest.current.cancel();
    onLoading();
    debounceTimer.current = setTimeout(() => void loadViewport(), 220);
  }, [loadViewport, onLoading]);

  useMapEvents({ moveend: scheduleLoad, zoomend: scheduleLoad });

  useEffect(() => {
    scheduleLoad();
    return () => {
      if (debounceTimer.current) clearTimeout(debounceTimer.current);
      latestRequest.current.cancel();
    };
  }, [scheduleLoad]);

  return null;
}

function GroupMarkers({ groups }: { groups: NationalMapGroup[] }) {
  const map = useMap();

  function zoomToGroup(group: NationalMapGroup) {
    const bounds = L.latLngBounds(
      [group.bounds.south, group.bounds.west],
      [group.bounds.north, group.bounds.east]
    );
    map.fitBounds(bounds, {
      padding: [24, 24],
      maxZoom: group.type === "region" ? 6 : 8
    });
  }

  return groups.map((group) => (
    <CircleMarker
      key={`${group.type}-${group.code}`}
      center={[group.latitude, group.longitude]}
      radius={group.type === "region" ? 10 : 7}
      pathOptions={{
        color: "#ffffff",
        fillColor: NATIONAL_MAP_GROUP_COLOR,
        fillOpacity: 0.94,
        weight: 2
      }}
      eventHandlers={{ click: () => zoomToGroup(group) }}
    >
      <Tooltip direction="top" offset={[0, -8]}>{group.name}</Tooltip>
      <Popup>
        <div className="nearby-map-popup">
          <strong>{group.name}</strong>
          <span>{group.type === "region" ? "Région" : "Département"} · {formatInteger(group.communeCount)} communes</span>
          <span>Repère de navigation, sans agrégat statistique.</span>
          <button type="button" className="map-zoom-button" onClick={() => zoomToGroup(group)}>
            Explorer
          </button>
        </div>
      </Popup>
    </CircleMarker>
  ));
}

function SelectedTerritoryFit({
  result,
  regionCode,
  departmentCode
}: {
  result: NationalMapResult;
  regionCode: string;
  departmentCode: string;
}) {
  const map = useMap();
  const lastFit = useRef("");
  const previousSelection = useRef("");

  useEffect(() => {
    const selectionKey = departmentCode
      ? `department:${departmentCode}`
      : regionCode
        ? `region:${regionCode}`
        : "";
    if (selectionKey !== previousSelection.current) {
      previousSelection.current = selectionKey;
      lastFit.current = "";
    }

    if (result.level === "region" && regionCode) {
      const group = result.groups.find((item) => item.code === regionCode);
      const key = `region:${regionCode}`;
      if (group && lastFit.current !== key) {
        lastFit.current = key;
        map.fitBounds(groupBounds(group), { padding: [24, 24], maxZoom: 6 });
      }
    }
    if (result.level === "department" && departmentCode) {
      const group = result.groups.find((item) => item.code === departmentCode);
      const key = `department:${departmentCode}`;
      if (group && lastFit.current !== key) {
        lastFit.current = key;
        map.fitBounds(groupBounds(group), { padding: [24, 24], maxZoom: 8 });
      }
    }
  }, [departmentCode, map, regionCode, result]);

  return null;
}

function groupBounds(group: NationalMapGroup) {
  return L.latLngBounds(
    [group.bounds.south, group.bounds.west],
    [group.bounds.north, group.bounds.east]
  );
}

function CommunePolygons({
  communes,
  year,
  criterion
}: {
  communes: NationalMapCommune[];
  year: number;
  criterion: NationalMapCriterion;
}) {
  return communes.map((commune) => {
    const visualStyle = getNationalMapFeatureVisualStyle({ type: "commune", point: commune }, criterion);
    return (
      <Polygon
        key={commune.inseeCode}
        positions={multiPolygonToLeafletPositions(commune.geometry)}
        pathOptions={{
          color: "#ffffff",
          fillColor: visualStyle?.fillColor ?? getNationalMapFeatureColor({ type: "commune", point: commune }, criterion),
          fillOpacity: visualStyle?.fillOpacity ?? 0.92,
          opacity: visualStyle?.borderOpacity ?? 1,
          dashArray: visualStyle?.dashArray ?? undefined,
          weight: visualStyle?.borderWeight ?? 1
        }}
      >
        <Popup>
          <div className="nearby-map-popup">
            <Link href={`/communes/${commune.inseeCode}?year=${year}`}>{commune.name}</Link>
            <span>{commune.departmentName} · {commune.regionName}</span>
            <span>Population : {formatPopulation(commune.population)}{commune.populationYear ? ` · Insee ${commune.populationYear}` : ""}</span>
            <PointMetric point={commune} criterion={criterion} year={year} />
          </div>
        </Popup>
      </Polygon>
    );
  });
}

function PointMetric({ point, criterion, year }: { point: NationalMapPoint; criterion: NationalMapCriterion; year: number }) {
  if (criterion.type === "salePrice" || criterion.type === "rentPrice") {
    const metric = point.propertyMarket;
    if (!metric || metric.status !== "published") {
      return <span>{propertyMarketStatusLabel(metric?.status ?? "no-data")}</span>;
    }
    const interval = formatPropertyMarketInterval(metric);
    return (
      <>
        <strong>
          {metric.kind === "sale" ? "Prix d’achat médian" : "Loyer d’annonce estimé"}
          {" · "}{propertyTypeLabel(metric.propertyType)} : {formatPropertyMarketValue(metric)}
        </strong>
        <span>
          {metric.kind === "sale"
            ? `${formatInteger(metric.sampleCount)} mutations éligibles`
            : `${formatInteger(metric.sampleCount)} observations communales`}
        </span>
        {interval ? <span>{interval}</span> : null}
        <span>{propertyMarketSourceLabel(metric)} · {metric.sourceYear ?? "année inconnue"}</span>
      </>
    );
  }

  if (criterion.type === "categoryRate") {
    if (point.categoryPublicationStatus !== "published") {
      return <span>{point.categoryPublicationStatus === "masked" ? "Valeur non publiée" : "Donnée indisponible"}</span>;
    }
    const rate = point.categoryRatePer1000 === null
      ? point.categoryRateDenominator === "unknown"
        ? "Taux indisponible · base inconnue"
        : "Taux indisponible"
      : formatCategoryRate(
          point.categoryRatePer1000,
          point.categoryRateDenominator,
          point.categoryPopulationDenominatorYear,
          point.categoryHousingDenominatorYear
        );
    return (
      <>
        <strong>{point.categoryLabel ?? "Catégorie sélectionnée"}</strong>
        <span>{formatInteger(point.categoryIncidentCount)} · {point.categoryCountUnit ?? "unité inconnue"}</span>
        <span>{rate}</span>
      </>
    );
  }

  if (criterion.type === "environmentalRisk") {
    const summary = point.environmentalRisk?.radiusKm === criterion.radiusKm
      ? point.environmentalRisk
      : null;
    if (!summary) return <span>Indice environnemental non disponible pour ce rayon</span>;
    return (
      <>
        <strong>Indice environnemental {criterion.radiusKm} km : {formatEnvironmentalRiskValue(summary.value)}</strong>
        <span>{formatEnvironmentalRiskStatus(summary.status)}</span>
        <span>{formatEnvironmentalRiskProvenance(summary.provenance)}</span>
        <span>{summary.scoredNeighborCount} / {summary.totalNeighborCount} communes voisines avec indice</span>
        {formatEnvironmentalRiskNeighborProvenance(summary).map((line) => (
          <span key={line}>{line}</span>
        ))}
        <span>Couverture pondérée : {formatEnvironmentalRiskCoverage(summary.weightedCoverageRatio)}</span>
      </>
    );
  }

  return (
    <>
      <strong>Indice d’exposition : {formatComparativeIndex(point.comparativeIndex.value)}</strong>
      <span>{comparativeIndexProvenanceLabel(point.comparativeIndex.provenance, year)}</span>
      <span>{comparativeIndexComponentCountLabel(point.comparativeIndex)}</span>
      {point.comparativeIndex.lowVolumeCapApplied ? <span>Plafond faible volume appliqué</span> : null}
      {point.comparativeIndex.estimatedComponentCount > 0 ? (
        <span title={describeComparativeIndex(point.comparativeIndex)}>
          Les estimations sont des moyennes départementales SSMSI des communes masquées.
        </span>
      ) : null}
      <span>Indice d’exposition calculé par l’application, pas une statistique officielle.</span>
    </>
  );
}
