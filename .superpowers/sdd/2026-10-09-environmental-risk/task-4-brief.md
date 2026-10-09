# Task 4: Environmental Map Layer and Full Verification

Read the approved design first: `docs/superpowers/specs/2026-10-09-environmental-risk-design.md`.
Read the map-point response contract in `src/client/nearby-map-ui.ts`, the environmental API state in `src/client/nearby-cities-ui.ts`, and the detail/map status formatters in `src/client/environmental-risk-ui.ts`.

## Files

- Modify: `src/client/nearby-cities-ui.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `app/nearby-cities-panel.tsx`
- Modify: `app/nearby-cities-map.tsx`
- Modify: `tests/nearby-map.test.ts`
- Create: `tests/nearby-cities-ui.test.ts`
- Modify: `app/globals.css` only if required for the selector or legend

## Interfaces

- Consume the optional `NearbyMapPoint.environmentalRisk` summary and `environmentalRadiusKm` API parameter implemented in Task 3.
- Define `NearbyMapCriterion` as `{ type: "comparativeIndex" } | { type: "categoryRate" } | { type: "environmentalRisk"; radiusKm: EnvironmentalRadiusKm }` in `src/client/nearby-map-ui.ts`.
- `getNearbyMapPointBand(point, criterion)` returns no band when the selected environmental summary is null, non-comparable, or has a different radius than the criterion. Otherwise, convert its 0–100 value to the existing 0–1 band input.
- The environmental map criterion selection must use submitted request state to stay aligned with the returned points while a newer request is loading. Selecting an environmental radius clears `mapCategoryCode`; selecting a category clears `mapEnvironmentalRadiusKm`; the default leaves both empty.
- Serialize non-empty `mapEnvironmentalRadiusKm` through `buildNearbySearchUrl` and omit it when no environmental map criterion is selected.

## Required Test-Driven Steps

1. In `tests/nearby-map.test.ts`, test each environmental radius criterion against a matching non-null score and assert that a null, non-comparable, or mismatched-radius summary uses `NEARBY_MAP_UNAVAILABLE_COLOR`. Keep existing comparative-index and category-rate tests unchanged. In `tests/nearby-cities-ui.test.ts`, assert that `buildNearbySearchUrl` includes the selected `environmentalRadiusKm` and omits it in default mode.
2. Run `npm test -- --reporter=verbose tests/nearby-map.test.ts tests/nearby-cities-ui.test.ts` and confirm the environmental criteria and URL field are missing.
3. Extend the map selector with « Environnement 25 km », « Environnement 50 km », « Environnement 100 km », and « Environnement 200 km ». Selecting one clears the category-rate criterion and requests the matching radius. Color each commune marker from its own environmental score; keep unavailable points gray. Show score, scored/total neighbors, and weighted coverage in marker popups. Keep the origin marker distinct. State that this is a commune-point layer, not commune polygons or a continuous surface.
4. Run `npm test -- --reporter=verbose tests/nearby-map.test.ts tests/nearby-cities-ui.test.ts`; expected: PASS for all radii, unavailable handling, selected-radius URL serialization, and existing criteria.
5. Run `npm test`; expected: all Vitest tests pass.
6. Run `npm run typecheck`; expected: TypeScript exits with code 0.
7. Run `npm run build`; expected: Next.js production build completes successfully.
8. Inspect local query plans and response times for commune detail and nearby-map environmental mode against the available database. Confirm the batch implementation does not regress the default nearby request. If local database access is unavailable, record that performance verification as unrun rather than inferring it from unit tests.

## Global Constraints

- Les statistiques officielles restent inchangées. L'indice environnemental est une valeur dérivée et identifiée comme telle.
- L'indice comparatif existant est la seule entrée de l'indice environnemental. Un indice manquant n'est jamais remplacé par zéro.
- La commune d'origine est exclue de son propre environnement.
- Les distances sont calculées à vol d'oiseau entre les points géographiques des communes.
- Les rayons proposés sont 25, 50, 100 et 200 km, comme dans la recherche de proximité.
- L'indice décrit une exposition statistique relative, pas une probabilité individuelle, un niveau de criminalité officiel ou une garantie de sécurité.
- Ne pas créer de migration ni de stockage persistant pour cette première version.
- Aucun commit.

## Reporting

Write the full implementation report to `.superpowers/sdd/2026-10-09-environmental-risk/task-4-report.md`. Do not create a Git repository, branch, worktree, or commit. Work serially in the shared workspace; the parent will review a before/after patch package.
