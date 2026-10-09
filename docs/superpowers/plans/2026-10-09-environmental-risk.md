# Environmental Risk Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a distance-weighted environmental score to commune details and a selectable environmental color layer to the nearby map.

**Architecture:** A shared server module queries geocoded neighbors from PostGIS for the requested year and active metrics snapshot, then calculates the same weighted summary for detail and map targets. Detail returns the four supported radii; the nearby API calculates the selected radius in one batch for all map points, never one query per marker. Raw SSMSI observations remain unchanged.

**Tech Stack:** Next.js, TypeScript, PostgreSQL/PostGIS, React Leaflet, Vitest.

**Spec:** `docs/superpowers/specs/2026-10-09-environmental-risk-design.md`

## Global Constraints

- Les statistiques officielles restent inchangées. L'indice environnemental est une valeur dérivée et identifiée comme telle.
- L'indice comparatif existant est la seule entrée de l'indice environnemental. Un indice manquant n'est jamais remplacé par zéro.
- La commune d'origine est exclue de son propre environnement.
- Les distances sont calculées à vol d'oiseau entre les points géographiques des communes.
- Les rayons proposés sont 25, 50, 100 et 200 km, comme dans la recherche de proximité.
- L'indice décrit une exposition statistique relative, pas une probabilité individuelle, un niveau de criminalité officiel ou une garantie de sécurité.
- Le poids est `1 - distance / rayon`; un score est disponible à partir de 3 voisines comparables et de 50 % de couverture pondérée.
- Ne pas créer de migration ni de stockage persistant pour cette première version.
- Aucun commit.

## Review Focus

- Une origine sans coordonnées, ou sans voisines, doit produire un état explicite et jamais un score zéro. Test in Task 1.
- Les voisines sans indice gardent leur poids au dénominateur de couverture et ne contribuent jamais au score comme zéro. Test in Task 1.
- Une commune à distance nulle reçoit un poids de 1; une commune exactement à la limite du rayon est exclue. Test in Task 1.
- Les métriques environnementales de la carte doivent être calculées contre toutes les communes géolocalisées du rayon, indépendamment des filtres de résultats et de la pagination de la liste. Test in Task 3.
- Les requêtes de fiche et de carte doivent réutiliser l'année et le snapshot transmis, même si un nouvel instantané devient actif entre-temps. Tests in Tasks 1 and 3.

---

### Task 1: Shared Environmental Metric and City Detail Data

**Files:**
- Create: `src/server/environmental-risk.ts`
- Create: `tests/environmental-risk.test.ts`
- Modify: `src/server/city-detail.ts`
- Modify: `tests/city-detail-query.test.ts`

**Interfaces:**
- Produces `ENVIRONMENTAL_RADII_KM: readonly [25, 50, 100, 200]`, `EnvironmentalRadiusKm`, `EnvironmentalRiskStatus`, `EnvironmentalRiskSummary`, `EnvironmentalNeighborRow`, `buildCityEnvironmentalRiskQuery(inseeCode, year, snapshotId)`, `buildMapEnvironmentalRiskQuery(inseeCodes, year, snapshotId, radiusKm)`, and `summarizeEnvironmentalRisk(targetCode, radiusKm, coordinatesAvailable, neighborRows)` from `src/server/environmental-risk.ts`.
- `EnvironmentalRiskSummary` has `radiusKm`, `value`, `status`, `scoredNeighborCount`, `totalNeighborCount`, and `weightedCoverageRatio`. Status values are `comparable`, `insufficient-coverage`, `no-neighbors`, and `coordinates-unavailable`.
- `EnvironmentalNeighborRow` has `targetInseeCode`, `neighborInseeCode`, `distanceKm`, and nullable `comparativeIndex`; the target query separately reports whether target coordinates are available.
- Consumes the `snapshot_id` returned by `buildCityDetailQuery`; detail uses the existing active snapshot for its environmental query just as it does for history and comparisons.

- [x] **Step 1: Write failing domain and SQL contract tests**

In `tests/environmental-risk.test.ts`, cover the weighted result (for a 25 km radius, indices 20 at 0 km, 80 at 12.5 km, and 40 at 10 km yield 40), origin exclusion, null index treatment, minimum three scored neighbors, 50% weighted coverage, zero-distance weight 1, strict radius boundary, no coordinates, and no neighbors. Also assert that city and map SQL use the supplied year and snapshot, exclude the target commune, and retain neighbors with null indices for the coverage denominator.

In `tests/city-detail-query.test.ts`, assert that `getCityDetail` sends the exact `snapshot_id` from its first row to the environmental query as well as history and comparisons.

- [x] **Step 2: Run the focused tests and confirm the new behavior is missing**

Run: `npm test -- --reporter=verbose tests/environmental-risk.test.ts tests/city-detail-query.test.ts`
Expected: FAIL because the environmental module and detail integration do not exist.

- [x] **Step 3: Implement shared neighbor queries and summary calculation**

In `src/server/environmental-risk.ts`, define the shared types and pure `summarizeEnvironmentalRisk` function. Calculate each weight as `1 - distanceKm / radiusKm`; count all geolocated neighbors in the coverage denominator and only non-null comparative indices in the score numerator. Return a null value unless there are at least three scored neighbors and weighted coverage is at least `0.5`. Return explicit statuses for missing coordinates, no neighbors, and insufficient coverage. Build parameterized PostGIS queries for one target at all four radii and a list of map targets at one selected radius, using the supplied snapshot ID and year.

- [x] **Step 4: Integrate environmental summaries into city detail**

Extend `CityDetail` with `environmentalRisk: EnvironmentalRiskSummary[]`. In `getCityDetail`, run the four-radius neighbor query in parallel with history and comparison queries, passing `row.snapshot_id`; group its rows by radius and call `summarizeEnvironmentalRisk` for each. Preserve four summary entries even when the city lacks coordinates or has no neighbors.

- [x] **Step 5: Run focused tests and confirm they pass**

Run: `npm test -- --reporter=verbose tests/environmental-risk.test.ts tests/city-detail-query.test.ts`
Expected: PASS, including snapshot identity and all weighted-coverage cases.

### Task 2: Commune Detail Presentation

**Files:**
- Create: `app/environmental-risk-section.tsx`
- Create: `src/client/environmental-risk-ui.ts`
- Modify: `app/communes/[inseeCode]/page.tsx`
- Modify: `app/globals.css`
- Create: `tests/environmental-risk-ui.test.ts`

**Interfaces:**
- Consumes `EnvironmentalRiskSummary[]` from Task 1.
- Produces `formatEnvironmentalRiskValue(value: number | null)`, `formatEnvironmentalRiskStatus(status: EnvironmentalRiskStatus)`, and `formatEnvironmentalRiskCoverage(ratio: number | null)` from `src/client/environmental-risk-ui.ts`.
- Produces a server-rendered section titled « Environnement statistique » with four rows, one per radius; a null score displays « Non disponible », never `0`.

- [x] **Step 1: Write failing presentation-helper tests**

Test `formatEnvironmentalRiskStatus` for all four statuses, `formatEnvironmentalRiskValue` for `42.5` and null, and `formatEnvironmentalRiskCoverage` for `0.52` and null. Assert null values display « Non disponible » and `getComparativeIndexClassName(null)` has no `stat-band-*` class.

- [x] **Step 2: Run the focused UI-helper tests and confirm they fail**

Run: `npm test -- --reporter=verbose tests/environmental-risk-ui.test.ts`
Expected: FAIL because the presentation helpers do not exist.

- [x] **Step 3: Implement the detail section and restrained layout**

Implement the three presentation helpers with French labels for `comparable`, `insufficient-coverage`, `no-neighbors`, and `coordinates-unavailable`. Render 25, 50, 100, and 200 km in a compact table or aligned list. For each row show the score, `scoredNeighborCount / totalNeighborCount`, and weighted coverage. Reuse `getComparativeIndexClassName` only for a non-null environmental value. Add a single methodological note explaining that this is an application-calculated distance-weighted mean of neighboring comparative indices, not an official SSMSI statistic or environmental percentile. Add the section to the commune detail page without nesting cards.

- [x] **Step 4: Run focused presentation tests**

Run: `npm test -- --reporter=verbose tests/environmental-risk-ui.test.ts`
Expected: PASS for statuses, coverage text, and null/color behavior.

### Task 3: Batch Environmental Values for the Nearby Map API

**Files:**
- Modify: `src/server/nearby-city-search.ts`
- Modify: `src/server/environmental-risk.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `tests/nearby-city-search.test.ts`

**Interfaces:**
- Consumes `buildMapEnvironmentalRiskQuery`, `summarizeEnvironmentalRisk`, and `EnvironmentalRadiusKm` from Task 1.
- Adds optional `environmentalRadiusKm` to nearby search parameters. When present, `NearbyMapPoint.environmentalRisk` contains exactly one summary for that radius; when absent it is `null`.
- Adds the optional environmental summary property to the shared map point type; Task 4 will use it to render the selected layer.
- The initial nearby query returns the snapshot ID used for its map points. The batch environmental query receives that ID and the unique codes from `mapPoints`.
- The existing API route already forwards parsed URL parameters and serializes the search result generically, so no route-handler change is needed.

- [x] **Step 1: Write failing batch-query and search tests**

Test that invalid radii are rejected, a selected radius is passed to one batch query for unique map-point codes, the batch receives the initial query's snapshot ID and year, and no environmental query runs when the feature is not selected. Assert the SQL candidate search is independent of nearby population/index/category filters and pagination. Test that a null neighboring index contributes to coverage but not the weighted score.

- [x] **Step 2: Run the nearby tests and confirm the feature is absent**

Run: `npm test -- --reporter=verbose tests/nearby-city-search.test.ts`
Expected: FAIL because the environmental radius and batched map values are not implemented.

- [x] **Step 3: Add optional one-batch map enrichment**

Parse `environmentalRadiusKm` as one of 25, 50, 100, or 200. Return the chosen snapshot ID with the initial map response. If a radius is present and map points exist, issue exactly one parameterized map-neighbor query for all unique point codes, map rows through `summarizeEnvironmentalRisk`, and attach summaries by commune code. Do not issue N+1 queries. Do not let visible-list filters change the set of neighbors used in each environmental summary.

- [x] **Step 4: Run nearby server tests**

Run: `npm test -- --reporter=verbose tests/nearby-city-search.test.ts`
Expected: PASS for batch count, snapshot/year consistency, filter independence, and absent optional mode.

### Task 4: Environmental Map Layer and Full Verification

**Files:**
- Modify: `src/client/nearby-cities-ui.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `app/nearby-cities-panel.tsx`
- Modify: `app/nearby-cities-map.tsx`
- Modify: `tests/nearby-map.test.ts`
- Create: `tests/nearby-cities-ui.test.ts`
- Modify: `app/globals.css` only if required for the selector or legend

**Interfaces:**
- Consumes `NearbyMapPoint.environmentalRisk` and `environmentalRadiusKm` from Task 3.
- Defines `NearbyMapCriterion` as `{ type: "comparativeIndex" } | { type: "categoryRate" } | { type: "environmentalRisk"; radiusKm: EnvironmentalRadiusKm }` in `src/client/nearby-map-ui.ts`.
- Adds map criteria for the four environmental radii. The selected radius is sent through the existing nearby request and updates the marker layer.

- [x] **Step 1: Write failing map criterion, color, and URL tests**

In `tests/nearby-map.test.ts`, test each environmental radius criterion against a matching non-null score and assert that a null, mismatched-radius, or insufficient-coverage summary uses `NEARBY_MAP_UNAVAILABLE_COLOR`. Ensure existing comparative-index and category-rate color tests remain unchanged. In `tests/nearby-cities-ui.test.ts`, assert that `buildNearbySearchUrl` includes the selected `environmentalRadiusKm` and omits it when no environmental criterion is selected.

- [x] **Step 2: Run the map tests and confirm the new criteria are missing**

Run: `npm test -- --reporter=verbose tests/nearby-map.test.ts tests/nearby-cities-ui.test.ts`
Expected: FAIL because the environmental map criteria and URL field are not implemented.

- [x] **Step 3: Implement the selectable point layer**

Extend the map selector with « Environnement 25 km », « Environnement 50 km », « Environnement 100 km », and « Environnement 200 km ». Selecting one clears the category-rate criterion and requests the matching radius. Color each commune marker from its own environmental score; keep unavailable points gray. Show score, scored/total neighbors, and weighted coverage in marker popups. Keep the origin marker distinct. State that this is a commune-point layer, not commune polygons or a continuous surface.

- [x] **Step 4: Run map tests and the complete verification set**

Run: `npm test -- --reporter=verbose tests/nearby-map.test.ts tests/nearby-cities-ui.test.ts`
Expected: PASS for all radii, unavailable handling, selected-radius URL serialization, and existing criteria.

Run: `npm test`
Expected: all Vitest tests pass.

Run: `npm run typecheck`
Expected: TypeScript exits with code 0.

Run: `npm run build`
Expected: Next.js production build completes successfully.

Inspect local query plans and response times for commune detail and nearby-map environmental mode against the available database. Confirm the batch implementation does not regress the default nearby request. If local database access is unavailable, record that performance verification as unrun rather than inferring it from unit tests.

## Completion

No commit. Report the touched files, verification results, whether local PostGIS performance checks ran, and the local app URL if the dev server is running.
