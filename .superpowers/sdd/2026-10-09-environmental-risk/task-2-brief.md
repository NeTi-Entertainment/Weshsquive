# Task 2: Commune Detail Presentation

Read the approved design first: `docs/superpowers/specs/2026-10-09-environmental-risk-design.md`.
Read Task 1's implementation contract in `src/server/environmental-risk.ts` and the `CityDetail.environmentalRisk` type in `src/server/city-detail.ts`.

## Files

- Create: `app/environmental-risk-section.tsx`
- Create: `src/client/environmental-risk-ui.ts`
- Modify: `app/communes/[inseeCode]/page.tsx`
- Modify: `app/globals.css`
- Create: `tests/environmental-risk-ui.test.ts`

## Interfaces

- Consume `EnvironmentalRiskSummary[]` from Task 1.
- Produce `formatEnvironmentalRiskValue(value: number | null)`, `formatEnvironmentalRiskStatus(status: EnvironmentalRiskStatus)`, and `formatEnvironmentalRiskCoverage(ratio: number | null)` from `src/client/environmental-risk-ui.ts`.
- Status labels: `comparable` → « Indice calculé »; `insufficient-coverage` → « Couverture insuffisante »; `no-neighbors` → « Aucune commune dans ce rayon »; `coordinates-unavailable` → « Coordonnées indisponibles ».
- Format scores using French number formatting with one fractional digit; null score → « Non disponible ». Format coverage as a French percentage with no fractional digits; null ratio → « Non renseignée ».
- Produce a server-rendered section titled « Environnement statistique » with four rows, one per radius; a null score displays « Non disponible », never `0`.

## Required Test-Driven Steps

1. Write failing tests for all status labels, value `42.5` and null, coverage `0.52` and null. Assert null values display « Non disponible » and `getComparativeIndexClassName(null)` has no `stat-band-*` class.
2. Run `npm test -- --reporter=verbose tests/environmental-risk-ui.test.ts` and confirm the helpers do not exist.
3. Implement the three helpers and render 25, 50, 100, and 200 km in a compact table or aligned list. For each row show the score, `scoredNeighborCount / totalNeighborCount`, and weighted coverage. Reuse `getComparativeIndexClassName` only for a non-null environmental value. Add one methodological note explaining that this is an application-calculated distance-weighted mean of neighboring comparative indices, not an official SSMSI statistic or environmental percentile. Add the section to the commune detail page without nesting cards.
4. Run `npm test -- --reporter=verbose tests/environmental-risk-ui.test.ts`; expected: PASS for statuses, coverage text, and null/color behavior.

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

Write the full implementation report to `.superpowers/sdd/2026-10-09-environmental-risk/task-2-report.md`. Do not create a Git repository, branch, worktree, or commit. Work serially in the shared workspace; the parent will review a before/after patch package.
