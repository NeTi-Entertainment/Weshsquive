# SSMSI Comparative Index v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the overly restrictive comparative index with an equal-weight average of per-category percentiles, using explicitly labelled SSMSI departmental fallbacks only when communal values are masked.

**Architecture:** A new additive migration repairs derived denominator metadata, exposes one auditable row per city/year/basket component, and derives the v2 score from published-only reference distributions. Atomic search snapshots carry the score and its provenance to every API; shared TypeScript contracts then drive consistent labels and visual treatments across search, detail, comparison, proximity, national map and environmental risk.

**Tech Stack:** PostgreSQL 16, PostGIS, SQL views and snapshot tables, PowerShell import/integration tests, Next.js 16, React 19, TypeScript 5.9, Vitest 5, Leaflet.

**Spec:** `docs/superpowers/specs/2026-10-10-ssmsi-comparative-index-v2-design.md`

## Global Constraints

- Never sum incident counts or rates across basket categories.
- Compute each category percentile against published communal rates from the same year, population band, count unit and denominator.
- Compute the final index as the equal-weight mean of comparable category percentiles, with no second ranking pass.
- A `diff` value is the communal value, including a published zero; an `ndiff` value remains null at communal level.
- Use `complement_info_taux` only for a derived score component and always expose its estimated provenance.
- Never use `complement_info_nombre` in the score or return either complement as a communal statistic.
- Reference distributions contain published communal values only and require at least 50 rows per component.
- Preserve the atomic snapshot switch and keep serving the previous generation on refresh failure.
- Do not add dependencies and do not create commits.

## Review Focus

- Published zero versus masked value: zero must score as published while `ndiff` remains null and can only contribute through the departmental fallback.
- Reference contamination: estimated complements must never enter the percentile reference distribution.
- Ties and extremes: equal rates must share a percentile, and fallback rates outside the published range must remain within 0-100.
- Annual drift: an unknown category, denominator mismatch or incomplete future source must fail or remain unavailable without silently receiving a score.
- Cross-screen consistency: the same snapshot, score and provenance must appear in search, detail, comparison, proximity, map and environmental calculations.

---

### Task 1: Database Formula and Auditable Components

**Files:**
- Create: `db/migrations/006_comparative_index_v2.sql`
- Create: `scripts/test_comparative_index_v2.ps1`
- Modify: `scripts/test_database_schema.ps1`

**Interfaces:**
- Produces view `city_year_comparative_components` with `city_insee_code`, `year`, `category_code`, `population_band`, `component_source`, `effective_rate_per_1000`, `reference_cohort_size` and `category_percentile`.
- Produces v2 columns in `city_year_comparative_metrics`: `estimated_basket_category_count`, `comparable_basket_category_count`, `estimated_availability_mask`, `minimum_reference_cohort_size`, `comparative_index_provenance`, `comparative_index_status`, `comparative_index`, and `basket_version`.
- Preserves all existing raw `crime_stats` values and publication statuses.

- [ ] **Step 1: Write the failing isolated database test**

Create `scripts/test_comparative_index_v2.ps1` using the existing temporary PostGIS-container pattern. Seed at least 50 published reference cities per category and explicit fixtures for published-only, partially estimated, estimated-only, published zero, `unknown`, missing population, equal rates and an out-of-range fallback. Assert:

- raw masked communal values remain null;
- only `complement_info_taux` supplies a masked component;
- an `unknown` row never uses a complement;
- the reference cohort counts only published rows;
- exact availability masks do not split the cohort;
- `50000-99999` and `100000-plus` resolve to `50000-plus`;
- percentile equals `count(reference_rate < effective_rate) / (reference_count - 1)` with 0-1 bounds;
- the final score is the rounded equal-weight mean and not a sum or second percentile;
- all four provenance values and all availability statuses are reachable.

- [ ] **Step 2: Run the database tests and confirm the new assertions fail**

Run: `pwsh -File scripts/test_comparative_index_v2.ps1`

Expected: FAIL because migration `006` and the component view do not exist.

- [ ] **Step 3: Implement migration `006_comparative_index_v2.sql`**

Add the official category-to-denominator corrections without changing official counts or rates. Reclassify `crime_stats.rate_denominator` only when the official denominator is known and the published count/rate arithmetic is consistent within the existing tolerance; masked rows may inherit the documented denominator, while contradictions stay `unknown`.

Create `city_year_comparative_components` so each basket component selects communal `rate_per_1000` first, then masked `complement_info_taux`, and joins a published-only reference distribution. Recreate `city_year_comparative_metrics` using five population bands, at least three comparable components, provenance counters and `residential-risk-v2`.

- [ ] **Step 4: Extend schema assertions and migration registration**

Update `scripts/test_database_schema.ps1` to assert the component view, new columns, v2 basket version, five-band boundary behavior and absence of destructive changes to `crime_stats`. Verify that the existing ordered migration runner discovers `006` on both fresh and upgraded databases.

- [ ] **Step 5: Run database formula and schema tests**

Run:

```powershell
pwsh -File scripts/test_comparative_index_v2.ps1
pwsh -File scripts/test_database_schema.ps1
```

Expected: both scripts complete successfully.

### Task 2: Atomic Snapshots and Import Guards

**Files:**
- Modify: `db/migrations/006_comparative_index_v2.sql`
- Modify: `db/refresh_search_metrics.sql`
- Modify: `scripts/import_crime_data_ssmsi.ps1`
- Modify: `scripts/test_import_crime_data_ssmsi.ps1`
- Modify: `scripts/test_comparative_index_v2.ps1`

**Interfaces:**
- Extends `search_metrics_city_year_category` with `complement_info_nombre` and `complement_info_taux` for internal derived calculations only.
- Extends `search_metrics_city_year_comparative` with the v2 counters, masks, cohort size and provenance produced by Task 1.
- Keeps `search_metrics_active.snapshot_id` as the sole atomic generation pointer.

- [ ] **Step 1: Add failing import and refresh assertions**

Extend the SSMSI fixture test to assert that `diff` rows ignore complements, `ndiff` rows keep communal values null, and denominators for all six basket categories match the official reference. Extend the v2 integration test to inject a refresh failure and assert that the active snapshot is unchanged.

- [ ] **Step 2: Run the targeted tests and confirm failure**

Run:

```powershell
pwsh -File scripts/test_import_crime_data_ssmsi.ps1
pwsh -File scripts/test_comparative_index_v2.ps1
```

Expected: FAIL on missing snapshot columns or v2 refresh values.

- [ ] **Step 3: Populate the extended snapshot atomically**

Update `db/refresh_search_metrics.sql` to copy complement fields into category snapshots and every v2 comparative field into comparative snapshots before changing `search_metrics_active`. Keep the advisory lock, `REPEATABLE READ` transaction, rollback semantics and two-generation retention.

- [ ] **Step 4: Strengthen SSMSI import validation**

Keep the current official denominator mapping, add a validation before the database transaction commits that each masked department/year/category group has at most one non-null complement pair, and reject a complement attached to a status other than `ndiff`. Continue refreshing metrics only after the import transaction succeeds.

- [ ] **Step 5: Run import, refresh and idempotence tests**

Run:

```powershell
pwsh -File scripts/test_import_crime_data_ssmsi.ps1
pwsh -File scripts/test_comparative_index_v2.ps1
```

Expected: PASS, including unchanged raw values and preserved active generation after forced failure.

### Task 3: Comparative Index Type and API Contracts

**Files:**
- Modify: `src/server/comparative-index.ts`
- Modify: `src/server/city-search.ts`
- Modify: `src/server/city-detail.ts`
- Modify: `src/server/nearby-city-search.ts`
- Modify: `src/server/national-map.ts`
- Modify: `src/client/city-search-ui.ts`
- Modify: `src/client/nearby-cities-ui.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `tests/comparative-index.test.ts`
- Modify: `tests/city-search-query.test.ts`
- Modify: `tests/city-detail-query.test.ts`
- Modify: `tests/nearby-city-search.test.ts`
- Modify: `tests/national-map.test.ts`
- Modify: `tests/city-search-ui.test.ts`
- Modify: `tests/nearby-cities-ui.test.ts`
- Modify: `tests/nearby-map.test.ts`

**Interfaces:**
- `ComparativeIndexProvenance = "published-only" | "partially-estimated" | "estimated-only" | "unavailable"`.
- `ComparativeIndex` exposes `provenance`, `publishedComponentCount`, `estimatedComponentCount`, `comparableComponentCount`, `minimumReferenceCohortSize`, `basketCategoryCount`, `basketAvailability`, `populationBand`, `status`, `value` and `basketVersion`.
- `comparativeIndexProvenanceLabel(provenance)` returns the four approved French labels.

- [ ] **Step 1: Update fixtures with failing v2 contract expectations**

Change query and mapping fixtures to expect `residential-risk-v2`, the four provenances, component counters and `reference-cohort-too-small`. Assert that category objects still expose masked communal values as null and do not contain either complement field.

- [ ] **Step 2: Run targeted TypeScript tests and confirm failure**

Run:

```powershell
npm test -- --run tests/comparative-index.test.ts tests/city-search-query.test.ts tests/city-detail-query.test.ts tests/nearby-city-search.test.ts tests/national-map.test.ts
```

Expected: FAIL on missing v2 fields and types.

- [ ] **Step 3: Implement the shared v2 mapper and labels**

Update `mapComparativeIndex` and `comparativeIndexMetadata` with the exact interfaces above. Keep `completeness` as basket completeness derived from `comparableComponentCount` (six high, four or five medium, three low), but remove every user-facing reference to statistical confidence.

- [ ] **Step 4: Select and map the same snapshot fields in every server query**

Update search, detail, nearby and national-map SQL projections and row types. Preserve filter and sort semantics on `comparative_index`; estimates remain eligible but their provenance is always returned. Keep the detail page's single captured `snapshot_id` across all subqueries.

- [ ] **Step 5: Run API contract and type checks**

Run:

```powershell
npm test -- --run tests/comparative-index.test.ts tests/city-search-query.test.ts tests/city-detail-query.test.ts tests/nearby-city-search.test.ts tests/national-map.test.ts tests/city-search-ui.test.ts tests/nearby-cities-ui.test.ts tests/nearby-map.test.ts
npm run typecheck
```

Expected: all targeted tests and typecheck pass.

### Task 4: Environmental Provenance Propagation

**Files:**
- Modify: `src/server/environmental-risk.ts`
- Modify: `src/client/environmental-risk-ui.ts`
- Modify: `tests/environmental-risk.test.ts`
- Modify: `tests/environmental-risk-ui.test.ts`
- Modify: `tests/national-map.test.ts`
- Modify: `tests/nearby-city-search.test.ts`

**Interfaces:**
- `EnvironmentalNeighborRow` gains `comparativeIndexProvenance`.
- `EnvironmentalRiskSummary` gains `provenance`, `publishedOnlyNeighborCount`, `partiallyEstimatedNeighborCount` and `estimatedOnlyNeighborCount`.
- A valid environmental score is `published-only` only when every scored neighbor is published-only; otherwise it is `partially-estimated`. An unavailable score has provenance `unavailable`.

- [ ] **Step 1: Write failing environmental provenance tests**

Cover all-published neighbors, a mixed neighborhood, estimated-only neighbors, missing scores, target exclusion and insufficient coverage. Assert that the numerical weighted average and existing thresholds remain unchanged.

- [ ] **Step 2: Run environmental tests and confirm failure**

Run: `npm test -- --run tests/environmental-risk.test.ts tests/environmental-risk-ui.test.ts`

Expected: FAIL because provenance and counters are absent.

- [ ] **Step 3: Propagate provenance through batch queries and summaries**

Select `comparative_index_provenance` alongside each neighbor score in both query builders. Extend `summarizeEnvironmentalRisk` to count scored-neighbor provenance and derive the summary provenance without treating an unavailable score as zero.

- [ ] **Step 4: Add environmental labels**

Add a formatter that distinguishes an environment based only on published communal indices from one containing departmental fallbacks. Preserve the existing warning that this is an application-derived weighted average, not an official SSMSI aggregate or percentile.

- [ ] **Step 5: Run environmental and dependent API tests**

Run:

```powershell
npm test -- --run tests/environmental-risk.test.ts tests/environmental-risk-ui.test.ts tests/national-map.test.ts tests/nearby-city-search.test.ts
npm run typecheck
```

Expected: PASS.

### Task 5: Provenance-Aware Interface and Map Styling

**Files:**
- Modify: `app/city-search-page.tsx`
- Modify: `app/city-comparison-table.tsx`
- Modify: `app/communes/[inseeCode]/page.tsx`
- Modify: `app/nearby-cities-panel.tsx`
- Modify: `app/nearby-cities-map.tsx`
- Modify: `app/france-map.tsx`
- Modify: `app/environmental-risk-section.tsx`
- Modify: `app/globals.css`
- Modify: `src/client/france-map-ui.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `tests/france-map-ui.test.ts`
- Modify: `tests/nearby-map.test.ts`
- Modify: `tests/city-search-ui.test.ts`
- Modify: `tests/environmental-risk-ui.test.ts`

**Interfaces:**
- Add `getComparativeIndexVisualStyle(value, provenance)` returning the existing band color plus fill opacity, border opacity and dash pattern.
- Published-only uses normal opacity and solid border; partially estimated uses reduced opacity and dashed border; estimated-only uses lower opacity and a stronger dashed border; unavailable remains gray.

- [ ] **Step 1: Write failing presentation-helper tests**

Assert the exact four French labels, gray only for unavailable scores, identical hue for equal index values regardless of provenance, and distinct opacity/dash styles for the three comparable provenance states.

- [ ] **Step 2: Run UI helper tests and confirm failure**

Run:

```powershell
npm test -- --run tests/city-search-ui.test.ts tests/france-map-ui.test.ts tests/nearby-map.test.ts tests/environmental-risk-ui.test.ts
```

Expected: FAIL on missing labels and marker-style helpers.

- [ ] **Step 3: Update tables, cards and popups**

Replace legacy confidence/cohort wording with the provenance label, component counts, population band and minimum published reference size. Keep masked category cells labelled `Non publié`; never surface fallback values as category facts or rates.

- [ ] **Step 4: Apply provenance-aware map marker styles and legends**

Pass the shared style object to Leaflet `CircleMarker` instances on national and nearby maps. Add one concise legend per map for published, partially estimated, entirely estimated and unavailable states. Keep category-rate and property-market layers unchanged.

- [ ] **Step 5: Update environmental UI annotations**

Show the three neighbor provenance counts where environmental details are displayed and add one methodological annotation per view when fallbacks contribute.

- [ ] **Step 6: Run UI tests, typecheck and build**

Run:

```powershell
npm test -- --run tests/city-search-ui.test.ts tests/france-map-ui.test.ts tests/nearby-map.test.ts tests/environmental-risk-ui.test.ts
npm run typecheck
npm run build
```

Expected: PASS with no text overflow or React/TypeScript errors.

### Task 6: Local Upgrade, Data Audit and End-to-End Verification

**Files:**
- Modify only if a verification reveals a defect in the files owned by Tasks 1-5.
- Record implementation progress in `.superpowers/sdd/2026-10-10-ssmsi-comparative-index-v2/progress.md` when using subagent-driven execution.

**Interfaces:**
- Activates migration `006` and a fresh `residential-risk-v2` snapshot in local database `app_criminalite`.
- Leaves the application available at `http://localhost:3000/`.

- [ ] **Step 1: Capture pre-migration raw checksums and counts**

Query counts and deterministic aggregates over `crime_stats` official fields (`incident_count`, `rate_per_1000`, `publication_status`, complements) before migration. Save the values in the execution log, not in application tables.

- [ ] **Step 2: Apply migrations and refresh the local snapshot**

Run:

```powershell
pwsh -File scripts/apply_migrations.ps1
pwsh -File scripts/refresh_search_metrics.ps1
```

Expected: migration `006` is recorded and a new active snapshot is reported.

- [ ] **Step 3: Audit local v2 distribution and raw-data invariants**

Assert the pre/post raw checksums match. Independently recompute representative published-only, partially estimated and estimated-only scores in SQL. Confirm approximately 1,875 published-only, 31,778 partially estimated, 1,199 estimated-only and 23 population-unavailable rows for 2025; investigate any difference rather than encoding these counts as product constants.

- [ ] **Step 4: Run the complete automated verification suite**

Run:

```powershell
npm test
npm run typecheck
npm run build
pwsh -File scripts/test_database_schema.ps1
pwsh -File scripts/test_comparative_index_v2.ps1
pwsh -File scripts/test_import_crime_data_ssmsi.ps1
pwsh -File scripts/test_annual_import_core.ps1
```

Expected: all checks pass, with only previously documented intentional skips.

- [ ] **Step 5: Measure query behavior**

Run representative simple search, combined search, nearby search, commune detail and national-map requests against the active snapshot. Use `EXPLAIN (ANALYZE, BUFFERS)` for regressions and confirm the v2 component calculation occurs during refresh, not per request.

- [ ] **Step 6: Verify desktop and mobile user journeys**

At desktop and mobile widths, inspect the main table, commune detail, comparison, nearby list/map and France map. Check one city for each provenance, switch between comparative, environmental, category and property layers, and verify that only true unavailability is gray while estimated markers remain visibly qualified and all popup text fits.

- [ ] **Step 7: Request final independent review**

Have a fresh reviewer inspect statistical correctness, raw-data separation, fallback leakage, query consistency and UI wording. Fix any critical or important finding and rerun the affected checks plus the complete Vitest suite.
