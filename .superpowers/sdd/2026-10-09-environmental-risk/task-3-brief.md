# Task 3: Batch Environmental Values for the Nearby Map API

Read the approved design first: `docs/superpowers/specs/2026-10-09-environmental-risk-design.md`.
Read the shared contracts in `src/server/environmental-risk.ts` and `src/server/nearby-city-search.ts` before changing them.

## Files

- Modify: `src/server/nearby-city-search.ts`
- Modify: `src/server/environmental-risk.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `tests/nearby-city-search.test.ts`

The route handler `app/api/cities/[inseeCode]/nearby/route.ts` already passes parsed query parameters to `searchNearbyCities` and serializes its result with a generic spread; do not modify that route.

## Interfaces

- Consume `buildMapEnvironmentalRiskQuery(inseeCodes, year, snapshotId, radiusKm)`, `summarizeEnvironmentalRisk`, and `EnvironmentalRadiusKm` from Task 1.
- Add optional `environmentalRadiusKm` to `NearbyCitySearchParams` and validate it against 25, 50, 100, 200.
- Add optional `environmentalRisk: EnvironmentalRiskSummary | null` to `NearbyMapPoint`. Search responses set it to null unless an environmental radius was requested and then attach the matching summary.
- The initial nearby query returns its active `snapshot_id` internally. The batch query receives that exact ID, the requested year, and the unique codes from `mapPoints`; do not expose the snapshot ID in the API response.

## Required Test-Driven Steps

1. Write failing tests in `tests/nearby-city-search.test.ts` for invalid radius rejection, one batch query for unique map-point codes, exact year and snapshot propagation, no batch query when the option is absent or there are no map points, and environment candidates independent of the nearby population/index/category filters and pagination. Confirm a null neighbor index remains in coverage and is never turned into zero.
2. Run `npm test -- --reporter=verbose tests/nearby-city-search.test.ts` and confirm the optional environmental mode is absent.
3. Parse `environmentalRadiusKm` as one of 25, 50, 100, or 200. Return the chosen snapshot ID from the initial nearby query internally. If a radius is present, map points exist, and a snapshot ID is available, issue exactly one parameterized environmental query for all unique map-point codes. Map the rows through `summarizeEnvironmentalRisk`, attach summaries by commune code, and do not issue N+1 queries. For every mapped target, search its environmental neighbors without applying the nearby result filters or pagination. When the mode is absent, set each map point's environmental summary to null and preserve the existing one-query behavior.
4. Run `npm test -- --reporter=verbose tests/nearby-city-search.test.ts`; expected: PASS for validation, batching, snapshot/year consistency, filter independence, null handling, and the unchanged default mode.

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

- The initial search may return an empty page while map points exist; use the map-point payload and snapshot ID, not the paginated result rows.
- A selected display filter may restrict which target points are shown, but must never restrict the neighborhood candidates used to calculate each target's environmental score.
- If the initial active snapshot is unavailable, do not query a guessed/current replacement snapshot or emit fabricated scores.
- The default nearby request must retain its current single-query behavior.

## Reporting

Write the full implementation report to `.superpowers/sdd/2026-10-09-environmental-risk/task-3-report.md`. Do not create a Git repository, branch, worktree, or commit. Work serially in the shared workspace; the parent will review a before/after patch package.
