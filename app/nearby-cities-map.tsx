"use client";

import { useEffect } from "react";
import { CircleMarker, MapContainer, Popup, TileLayer, useMap } from "react-leaflet";
import L from "leaflet";

import {
  comparativeIndexCompletenessLabel,
  comparativeIndexStatusLabel,
  formatCategoryRate,
  formatComparativeIndex,
  formatPopulation
} from "@/client/city-search-ui";
import {
  formatEnvironmentalRiskCoverage,
  formatEnvironmentalRiskStatus,
  formatEnvironmentalRiskValue
} from "@/client/environmental-risk-ui";
import {
  getNearbyMapPointColor,
  type NearbyMapCriterion,
  type NearbyMapPoint
} from "@/client/nearby-map-ui";
import { formatDistance } from "@/client/nearby-cities-ui";

type NearbyCitiesMapProps = {
  origin: {
    inseeCode: string;
    name: string;
    latitude: number;
    longitude: number;
  };
  year: number;
  points: NearbyMapPoint[];
  criterion: NearbyMapCriterion;
};

function FitNearbyBounds({ origin, points }: Pick<NearbyCitiesMapProps, "origin" | "points">) {
  const map = useMap();

  useEffect(() => {
    const bounds = L.latLngBounds([[origin.latitude, origin.longitude]]);
    for (const point of points) {
      bounds.extend([point.latitude, point.longitude]);
    }
    map.fitBounds(bounds, { padding: [28, 28], maxZoom: 12 });
  }, [map, origin.latitude, origin.longitude, points]);

  return null;
}

function MapMetric({ point, criterion }: { point: NearbyMapPoint; criterion: NearbyMapCriterion }) {
  if (criterion.type === "categoryRate") {
    if (point.categoryPublicationStatus !== "published" || point.categoryRatePer1000 === null) {
      return <span>Valeur non publiée</span>;
    }

    return (
      <>
        <strong>{point.categoryLabel}</strong>
        <span>
          {formatCategoryRate(
            point.categoryRatePer1000,
            point.categoryRateDenominator,
            point.categoryPopulationDenominatorYear,
            point.categoryHousingDenominatorYear
          )}
        </span>
        <span>{point.categoryCountUnit ?? "Unité inconnue"}</span>
      </>
    );
  }

  if (criterion.type === "environmentalRisk") {
    const summary = point.environmentalRisk?.radiusKm === criterion.radiusKm
      ? point.environmentalRisk
      : null;
    if (!summary) {
      return <span>Indice environnemental non disponible pour ce rayon</span>;
    }

    return (
      <>
        <strong>
          Environnement {criterion.radiusKm} km : {formatEnvironmentalRiskValue(summary.value)}
        </strong>
        <span>{formatEnvironmentalRiskStatus(summary.status)}</span>
        <span>
          {summary.scoredNeighborCount} / {summary.totalNeighborCount} communes voisines avec indice
        </span>
        <span>
          Couverture pondérée : {formatEnvironmentalRiskCoverage(summary.weightedCoverageRatio)}
        </span>
      </>
    );
  }

  return (
    <>
      <strong>Indice comparatif : {formatComparativeIndex(point.comparativeIndex)}</strong>
      <span>
        {point.comparativeIndexCompleteness
          ? comparativeIndexCompletenessLabel(point.comparativeIndexCompleteness)
          : comparativeIndexStatusLabel(point.comparativeIndexStatus as "comparable" | "insufficient-coverage" | "cohort-too-small" | "population-unavailable")}
      </span>
    </>
  );
}

export default function NearbyCitiesMap({ origin, year, points, criterion }: NearbyCitiesMapProps) {
  return (
    <MapContainer
      className="nearby-map-canvas"
      center={[origin.latitude, origin.longitude]}
      zoom={10}
      minZoom={4}
      preferCanvas
      scrollWheelZoom
    >
      <TileLayer
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
      />
      <FitNearbyBounds origin={origin} points={points} />
      <CircleMarker
        center={[origin.latitude, origin.longitude]}
        radius={8}
        pathOptions={{ color: "#ffffff", fillColor: "#214f7a", fillOpacity: 1, weight: 2 }}
      >
        <Popup>
          <div className="nearby-map-popup">
            <strong>{origin.name}</strong>
            <span>Commune d’origine</span>
          </div>
        </Popup>
      </CircleMarker>
      {points.map((point) => (
        <CircleMarker
          key={point.inseeCode}
          center={[point.latitude, point.longitude]}
          radius={6}
          pathOptions={{
            color: "#ffffff",
            fillColor: getNearbyMapPointColor(point, criterion),
            fillOpacity: 0.9,
            weight: 1
          }}
        >
          <Popup>
            <div className="nearby-map-popup">
              <a href={`/communes/${point.inseeCode}?year=${year}`}>{point.name}</a>
              <span>{formatDistance(point.distanceKm)} · {formatPopulation(point.population)} habitants</span>
              <MapMetric point={point} criterion={criterion} />
            </div>
          </Popup>
        </CircleMarker>
      ))}
    </MapContainer>
  );
}
