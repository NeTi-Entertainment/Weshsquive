# Task 4: Selectable Environmental Map Layers

## Implementation

- Added the exact `NearbyMapCriterion` discriminated union for comparative index, category rate, and environmental risk with a typed radius.
- Added map-specific `mapEnvironmentalRadiusKm` state. Selecting an environmental radius clears the map category; selecting a category clears the radius; the comparative-index default clears both.
- `buildNearbySearchUrl` now serializes a selected radius as `environmentalRadiusKm`, omits it in default mode, and omits `mapCategoryCode` when environmental mode is selected.
- The panel derives both its selected map criterion and selector value from `submittedForm`. Pending requests therefore keep the current layer aligned with the points already displayed.
- Added four environmental-radius options. Point colors use each point's matching, comparable environmental score on the existing 0-100 band scale. Missing, non-comparable, and mismatched-radius summaries remain gray.
- Environmental marker popups show the score, status, scored/total neighboring communes, and weighted coverage. The origin marker remains visually distinct.
- Added the methodological note that the layer is an application-calculated weighted mean of neighboring comparative indices, not an official statistic, environmental percentile, or individual-risk measure. The UI also says this is a point map, not commune polygons or a continuous surface.
- No API response, official statistic, schema, migration, or persistent storage changed. CSS required no adjustment.

## TDD Evidence

The initial focused run failed as intended: environmental criteria were treated as the comparative index and the URL omitted `environmentalRadiusKm`. Additional state-transition tests failed because the selection helpers did not yet exist. After implementation, the focused suite passed.

Tests cover all four radii, gray handling for absent/non-comparable/mismatched summaries, category/environment/default state transitions, URL inclusion/omission, and the existing comparative-index and category-rate behavior.

## Verification

- `npm test -- --reporter=verbose tests/nearby-map.test.ts tests/nearby-cities-ui.test.ts`: **14 passed**.
- `npm test`: **81 passed, 1 skipped**, across 12 test files (1 file skipped), after the final weighted-coverage test refinement.
- `npm run typecheck`: passed.
- `npm run build`: passed; Next.js production build completed.
- Final-review follow-up: the exact 50% weighted-coverage case now differs from row-count coverage, with a second case proving that 50% row coverage can still fail the weighted threshold. `npm test -- tests/environmental-risk.test.ts`: **14 passed**; scoped re-review approved.
- Live API smoke check against the local database: commune detail and nearby requests returned HTTP 200. Environmental mode returned summaries for all **560/560** map points; default mode returned points without environmental summaries.

## Local Database and Performance Check

PostgreSQL/PostGIS was available. Read-only `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` checks used the local 2025 snapshot and commune `01002`:

- Main commune-detail query: **262 ms** execution, 293 shared-hit blocks, 0 shared-read blocks. It used the city, region, active-snapshot, comparative-metrics, and category indexes.
- Commune-detail environmental spatial query: **120 ms** execution, 34,085 shared-hit blocks, 0 shared-read blocks, no temporary blocks. It used `cities_geom_gix` and `search_metrics_comparative_year_lookup_idx`.
- Nearby-map environmental batch for **560 unique points** at 25 km: **931 ms** execution, 368,354 shared-hit blocks, 0 shared-read blocks, 354 temporary-read and 355 temporary-written blocks. It used `cities_geom_gix` and `search_metrics_comparative_year_lookup_idx`.

Three warm end-to-end API samples, in milliseconds:

- Commune detail: `2950, 2836, 2841` (median **2841 ms**).
- Nearby, default layer: `179, 120, 121` (median **121 ms**).
- Nearby, environmental 25 km layer: `1182, 1172, 1193` (median **1182 ms**).

The default nearby path remains separate from the environmental batch; this was also covered by the existing tests that assert no batch query without a selected environmental radius. The local measurements are indicative only, not CI thresholds. The detail response timing covers history and territorial comparisons too; those secondary queries were not individually timed here. The database was not modified by the checks.

## Limits

- The local commune-detail route loaded in the browser; its accessibility tree showed the map, selector, and all four environmental radii. I did not activate the selector or take a screenshot/manual visual pass.
- No Git repository, branch, worktree, or commit was created.
