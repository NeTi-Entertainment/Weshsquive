# Task 1: Shared Environmental Metric and City Detail Data

Read the approved design first: `docs/superpowers/specs/2026-10-09-environmental-risk-design.md`.

## Files

- Create: `src/server/environmental-risk.ts`
- Create: `tests/environmental-risk.test.ts`
- Modify: `src/server/city-detail.ts`
- Modify: `tests/city-detail-query.test.ts`

## Interfaces

- Produce `ENVIRONMENTAL_RADII_KM: readonly [25, 50, 100, 200]`, `EnvironmentalRadiusKm`, `EnvironmentalRiskStatus`, `EnvironmentalRiskSummary`, `EnvironmentalNeighborRow`, `buildCityEnvironmentalRiskQuery(inseeCode, year, snapshotId)`, `buildMapEnvironmentalRiskQuery(inseeCodes, year, snapshotId, radiusKm)`, and `summarizeEnvironmentalRisk(targetCode, radiusKm, coordinatesAvailable, neighborRows)` from `src/server/environmental-risk.ts`.
- `EnvironmentalRiskSummary` has `radiusKm`, `value`, `status`, `scoredNeighborCount`, `totalNeighborCount`, and `weightedCoverageRatio`. Status values are `comparable`, `insufficient-coverage`, `no-neighbors`, and `coordinates-unavailable`.
- `EnvironmentalNeighborRow` has `targetInseeCode`, `neighborInseeCode`, `distanceKm`, and nullable `comparativeIndex`; the target query separately reports whether target coordinates are available.
- Consume the `snapshot_id` returned by `buildCityDetailQuery`; detail uses the existing active snapshot for its environmental query just as it does for history and comparisons.

## Required Test-Driven Steps

1. Write failing tests in `tests/environmental-risk.test.ts` for the weighted result (for a 25 km radius, indices 20 at 0 km, 80 at 12.5 km, and 40 at 10 km yield 40), origin exclusion, null index treatment, minimum three scored neighbors, 50% weighted coverage, zero-distance weight 1, strict radius boundary, no coordinates, and no neighbors. Assert that city and map SQL use the supplied year and snapshot, exclude the target commune, and retain neighbors with null indices for the coverage denominator.
2. In `tests/city-detail-query.test.ts`, assert that `getCityDetail` sends the exact `snapshot_id` from its first row to the environmental query as well as history and comparisons.
3. Run `npm test -- --reporter=verbose tests/environmental-risk.test.ts tests/city-detail-query.test.ts` and confirm the new behavior is missing.
4. Implement the shared types and pure `summarizeEnvironmentalRisk` function. Calculate each weight as `1 - distanceKm / radiusKm`; count all geolocated neighbors in the coverage denominator and only non-null comparative indices in the score numerator. Return a null value unless there are at least three scored neighbors and weighted coverage is at least `0.5`. Return explicit statuses for missing coordinates, no neighbors, and insufficient coverage. Build parameterized PostGIS queries for one target at all four radii and a list of map targets at one selected radius, using the supplied snapshot ID and year.
5. Extend `CityDetail` with `environmentalRisk: EnvironmentalRiskSummary[]`. In `getCityDetail`, run the four-radius neighbor query in parallel with history and comparison queries, passing `row.snapshot_id`; group its rows by radius and call `summarizeEnvironmentalRisk` for each. Preserve four summary entries even when the city lacks coordinates or has no neighbors.
6. Run `npm test -- --reporter=verbose tests/environmental-risk.test.ts tests/city-detail-query.test.ts`; expected: PASS, including snapshot identity and all weighted-coverage cases.

## Global Constraints

- Les statistiques officielles restent inchangées. L'indice environnemental est une valeur dérivée et identifiée comme telle.
- L'indice comparatif existant est la seule entrée de l'indice environnemental. Un indice manquant n'est jamais remplacé par zéro.
- La commune d'origine est exclue de son propre environnement.
- Les distances sont calculées à vol d'oiseau entre les points géographiques des communes.
- Les rayons proposés sont 25, 50, 100 et 200 km, comme dans la recherche de proximité.
- L'indice décrit une exposition statistique relative, pas une probabilité individuelle, un niveau de criminalité officiel ou une garantie de sécurité.
- Ne pas créer de migration ni de stockage persistant pour cette première version.
- Aucun commit.

## Review Focus

- Une origine sans coordonnées, ou sans voisines, doit produire un état explicite et jamais un score zéro.
- Les voisines sans indice gardent leur poids au dénominateur de couverture et ne contribuent jamais au score comme zéro.
- Une commune à distance nulle reçoit un poids de 1; une commune exactement à la limite du rayon est exclue.
- Les requêtes de fiche doivent réutiliser l'année et le snapshot transmis.

## Reporting

Write the full implementation report to `.superpowers/sdd/2026-10-09-environmental-risk/task-1-report.md`. Do not create a Git repository, branch, commit, or worktree. The parent task will review the changes using a before/after snapshot diff because this workspace is shared and has no Git metadata.
