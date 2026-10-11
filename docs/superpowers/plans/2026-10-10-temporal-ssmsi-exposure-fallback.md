# Temporal SSMSI Exposure Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefer each commune's latest published SSMSI rate in N through N-3 for each exposure-index category, falling back only then to the target-year department complement, while keeping all raw observations unchanged.

**Architecture:** An additive migration will make the comparative-component view select a valid same-commune historical observation independently per category, then retain target-year raw fields for display and the low-volume rule. A one-pass, transactional importer extension will backfill 2016–2024 with annual batches; atomic snapshots will carry per-category and aggregate provenance to existing APIs, UI, and environmental summaries.

**Tech Stack:** PostgreSQL 16, PostGIS, SQL views and atomic search snapshots, PowerShell 7, Next.js 16, React 19, TypeScript 5.9, Vitest 5.

**Spec:** `docs/superpowers/specs/2026-10-10-temporal-ssmsi-exposure-fallback-design.md`

## Global Constraints

- Backfill 2016–2024 from the official consolidated SSMSI communal CSV; keep the normal annual importer behavior for new years.
- For an index year N, search communal published values only in N, N-1, N-2, N-3, in that order, independently for each basket category.
- Only after those candidates fail, use `complement_info_taux` from the target-year `ndiff` row; never use historical complements.
- Preserve raw `diff`, `ndiff`, `unknown`, counts, rates, denominators, and import provenance; a historical or estimated component never replaces target-year communal display data.
- Keep the six fixed 2025 anchors and `min(100, rate / anchor * 100)`, with equal component weights; expose an index only with at least 3 usable components.
- Keep X=10 based only on published, homogeneous `Infraction` counts from the target year and current-year published basket coverage.
- Match historical observations only by exact current city INSEE code; do not infer merger, split, or code-change correspondences.
- Keep category-map coloring based on target-year published values; temporal fallback applies only to the overall exposure index.
- Use additive migrations and atomic snapshot activation; do not add dependencies or create commits.

## Review Focus

- N-4 or older published data, or a historical masked row, must never outrank the target-year department fallback; pin this in the component-view integration test.
- A valid published zero must outrank older positive rates and complements; pin this in the component-view test.
- A current-year `unknown`, denominator mismatch, or wrong unit must not become published through history or a complement; pin this in the component-view test.
- A partial or failed backfill must not delete 2025 or activate an incomplete snapshot; pin this in importer and snapshot integration tests.
- Indices with 0–2 usable components remain unavailable while retaining honest coverage/provenance counts; pin this in SQL and TypeScript mapper tests.

---

### Task 1: Generic SSMSI Geography and One-Pass Historical Backfill

**Files:**
- Modify: `scripts/import_crime_data_ssmsi.ps1`
- Create: `scripts/backfill_ssmsi_history.ps1`
- Modify: `scripts/test_import_crime_data_ssmsi.ps1`
- Create: `scripts/test_backfill_ssmsi_history.ps1`
- Modify: `docs/imports-annuels.md`

**Interfaces:**
- `import_crime_data_ssmsi.ps1` keeps `-Year` and adds mutually exclusive `-Years [int[]]`; both continue to accept `-CrimeFileUrl`, optional `-GeographyYear`, and `-DeferMetricsRefresh`.
- When `-GeographyYear` is omitted, the importer accepts and validates exactly one `CODGEO_20xx` first column; when supplied, it must match. SQL stages this first field as `codgeo` and joins `cities.insee_code = raw.codgeo`.
- `backfill_ssmsi_history.ps1` defaults to years 2016–2024, resolves the latest compatible official communal resource unless `-CrimeFileUrl` is supplied, invokes one importer load for the selected years, and refreshes metrics once after a successful commit.
- The importer creates one completed `import_batches` record per selected year and assigns each imported row to its matching batch. Its delete/upsert scope is exactly the selected year set and source.

- [x] **Step 1: Add failing importer tests**

Extend `scripts/test_import_crime_data_ssmsi.ps1` with fixture CSVs whose first columns are `CODGEO_2024` and `CODGEO_2027`. Assert omitted geography year is inferred, explicit mismatch fails before database mutation, and exact-code matching remains required. Add a multi-year fixture containing 2016, 2017, 2024 and a sentinel 2025 row; assert `-Years 2016,2017,2024` creates one batch per requested year, imports only those years, and leaves every seeded 2025 `crime_stats` field and `imported_at` unchanged.

- [x] **Step 2: Run importer tests and confirm the new assertions fail**

Run: `pwsh -NoProfile -File scripts/test_import_crime_data_ssmsi.ps1`

Expected: existing assertions pass; new geography and multi-year assertions fail because the SQL references `codgeo_2026` and only supports one selected year.

- [x] **Step 3: Add a failing backfill-script integration test**

Create `scripts/test_backfill_ssmsi_history.ps1` using the existing temporary PostGIS-container pattern. Run the backfill twice against a local consolidated fixture and assert: selected years are 2016–2024; the second run creates no duplicate `crime_stats` rows; each year has its own batch; 2025 rows remain byte-for-byte equivalent across all raw fields and timestamps; an absent requested year fails without partial commits or a metric refresh; and the active snapshot is refreshed once after successful import.

- [x] **Step 4: Run the backfill test and confirm it fails for the missing interface**

Run: `pwsh -NoProfile -File scripts/test_backfill_ssmsi_history.ps1`

Expected: FAIL because `-Years` and the backfill runner do not exist.

- [x] **Step 5: Implement generic staging and multi-year selection**

In `scripts/import_crime_data_ssmsi.ps1`, normalize the geography column to `codgeo`; validate `-Year`/`-Years` exclusivity and unique years; generate a selected-year relation for SQL guards, year-scoped replacement, source filtering and per-year import batches. Keep the existing single-year and all-years code paths behaviorally compatible. A requested year with no source rows aborts the transaction.

- [x] **Step 6: Implement the backfill orchestrator and document its operation**

In `scripts/backfill_ssmsi_history.ps1`, resolve the latest communal release via `Get-LatestSsmiRelease` from `scripts/annual_import_core.psm1`, allow a local/source URL override for tests and offline runs, reject requested years outside 2016–2024 by default, call the importer once with `-Years`, then call `scripts/refresh_search_metrics.ps1` once. If import fails, do not refresh. Document preview, execution, idempotence, and the strict year scope in `docs/imports-annuels.md`.

- [x] **Step 7: Run importer and backfill tests**

Run:

```powershell
pwsh -NoProfile -File scripts/test_import_crime_data_ssmsi.ps1
pwsh -NoProfile -File scripts/test_backfill_ssmsi_history.ps1
```

Expected: both exit 0; the 2025 sentinel remains unchanged after each import and rerun.

### Task 2: Temporal Component Selection and Index Threshold

**Files:**
- Create: `db/migrations/009_temporal_exposure_fallback.sql`
- Modify: `scripts/test_comparative_index_v2.ps1`
- Modify: `scripts/test_database_schema.ps1`

**Interfaces:**
- `city_year_comparative_components` keeps one row per commune/year/basket category and adds `source_year`, `component_source`, `effective_rate_per_1000`, and `component_exposure_score`.
- `component_source` is one of `current-published`, `historical-published`, `department-masked-average`, or `unavailable`.
- `city_year_comparative_metrics` adds `historical_published_basket_category_count`, `historical_availability_mask`, and `oldest_exposure_source_year`; existing `published_basket_category_count` remains the count published in the target year.
- `comparative_index_status` is `available` only when at least 3 of 6 effective components exist; otherwise its value is NULL and status/provenance are `unavailable`.

- [x] **Step 1: Add failing migration and SQL fixture assertions**

Extend `scripts/test_comparative_index_v2.ps1` with a commune/category matrix covering: target-year published rate; target-year published zero; historical values in N-1, N-2 and N-3; competing N-4 value; historical `ndiff`; target-year complement; unit and denominator mismatch; and missing observations. Assert the selected source year/rate/source for each category, exact 3-of-6 availability boundary, current-year-only guardrail, and unchanged target-year raw fields. Add fresh-install and upgrade assertions for migration 009 in `scripts/test_database_schema.ps1`.

- [x] **Step 2: Run SQL tests and verify the temporal cases fail**

Run:

```powershell
pwsh -NoProfile -File scripts/test_comparative_index_v2.ps1
pwsh -NoProfile -File scripts/test_database_schema.ps1
```

Expected: existing v1 absolute-exposure checks pass; temporal selection, 3-component minimum and migration-009 assertions fail.

- [x] **Step 3: Implement the additive temporal selection view**

In `db/migrations/009_temporal_exposure_fallback.sql`, replace the derived component and comparative views without modifying `crime_stats`. For each target commune/category, use a lateral candidate lookup restricted to the same code, category, valid anchor unit/denominator, `publication_status = 'published'`, nonnegative non-NULL rate, and year between target N-3 and N; order by year descending. If none exists, admit only target-year `masked` `complement_info_taux` with matching anchor unit/denominator. Keep target-year `incident_count`, publication status and unit separately for the guardrail. Summarize masks/counts/source year; apply the minimum of 3; preserve the existing fixed anchors/formula and X=10 conditions.

- [x] **Step 4: Run migration and SQL integration tests**

Run:

```powershell
pwsh -NoProfile -File scripts/test_comparative_index_v2.ps1
pwsh -NoProfile -File scripts/test_database_schema.ps1
```

Expected: all temporal-priority, zero, mismatch, masked, minimum-coverage, guardrail, fresh-install and upgrade assertions pass; no test reports a changed raw target-year row.

### Task 3: Snapshot Persistence and Atomic Refresh

**Files:**
- Modify: `db/migrations/009_temporal_exposure_fallback.sql`
- Modify: `db/refresh_search_metrics.sql`
- Modify: `scripts/test_comparative_index_v2.ps1`

**Interfaces:**
- `search_metrics_city_year_category` stores `category_exposure_source_year smallint`, `category_exposure_rate_per_1000 numeric`, `category_exposure_score numeric`, and `category_exposure_source text` for every basket component; non-basket categories keep these values NULL.
- `search_metrics_city_year_comparative` stores current published, historical published, estimated and effective counts, the historical availability mask, oldest effective source year, status, provenance, basket version `absolute-exposure-v2`, and the low-volume-cap flag.
- `db/refresh_search_metrics.sql` continues building a new snapshot under repeatable-read and only updates `search_metrics_active` after all rows are inserted successfully.

- [x] **Step 1: Add failing snapshot assertions**

Extend `scripts/test_comparative_index_v2.ps1` to assert per-category source year/rate/provenance survives into the active snapshot; aggregate counts and oldest year match the view; migration/rebuild can be rerun; and an injected refresh failure leaves the previous active snapshot ID and contents unchanged.

- [x] **Step 2: Run the snapshot integration test and verify the new assertions fail**

Run: `pwsh -NoProfile -File scripts/test_comparative_index_v2.ps1`

Expected: FAIL because the snapshot tables and refresh insert do not yet contain temporal provenance fields.

- [x] **Step 3: Add snapshot columns and copy component metadata**

Add the columns additively in migration 009. Update `db/refresh_search_metrics.sql` to copy selected component metadata by the exact commune/year/category key and the aggregate metadata by commune/year. Do not join historical values into the raw `incident_count`, `rate_per_1000`, or publication status columns. Keep pointer activation after all inserts and preserve the prior generation on rollback.

- [x] **Step 4: Run snapshot integration test**

Run: `pwsh -NoProfile -File scripts/test_comparative_index_v2.ps1`

Expected: PASS for provenance persistence, one-row-per-key uniqueness, idempotent refresh, failure rollback and atomic activation.

### Task 4: Shared Types, API Mapping, and Commune Detail

**Files:**
- Modify: `src/shared/exposure-index.ts`
- Modify: `src/server/comparative-index.ts`
- Modify: `src/server/city-search.ts`
- Modify: `src/server/city-detail.ts`
- Modify: `app/communes/[inseeCode]/page.tsx`
- Modify: `tests/comparative-index.test.ts`
- Modify: `tests/city-search-query.test.ts`
- Modify: `tests/city-detail-query.test.ts`

**Interfaces:**
- `EXPOSURE_INDEX_VERSION` becomes `absolute-exposure-v2`.
- `ComparativeIndexProvenance` adds `historical-published`; existing `published-only` means all effective components came from the target year.
- `ComparativeIndex` exposes `historicalPublishedComponentCount` and `oldestSourceYear`; `publishedComponentCount` continues to mean current-year published components, `estimatedComponentCount` means target-year departmental fallback components, and `availableComponentCount` includes all three usable sources.
- Each search/detail category object adds `exposureSourceYear`, `exposureProvenance`, `exposureRatePer1000`, and `exposureScore`; these are derived fields, distinct from its target-year raw count/rate/status.
- Methodology metadata declares a maximum three-year communal lookback and a three-component minimum; the fixed anchors, formula and lack of smoothing remain unchanged.

- [x] **Step 1: Add failing mapper and query tests**

In `tests/comparative-index.test.ts`, assert all five global provenance cases, target/historical/estimated counts, oldest year, 3-of-6 unavailability, and v2 methodology fields. In `tests/city-search-query.test.ts` and `tests/city-detail-query.test.ts`, assert category exposure source year/rate/score/provenance are selected from the active snapshot while raw target-year `ndiff` fields stay NULL and explicitly masked.

- [x] **Step 2: Run TypeScript tests to verify failures**

Run: `npm test -- tests/comparative-index.test.ts tests/city-search-query.test.ts tests/city-detail-query.test.ts`

Expected: FAIL on missing v2 metadata, mapping fields and derived per-category API fields.

- [x] **Step 3: Implement shared v2 mapping and category detail fields**

Update `src/shared/exposure-index.ts` and `src/server/comparative-index.ts` to map exact SQL fields and labels. Update search and detail query shapes/parsers to expose snapshot provenance per category without substituting it for official target-year values. In `app/communes/[inseeCode]/page.tsx`, show source year/provenance in the category detail and preserve “Non publié” for target-year masked raw values.

- [x] **Step 4: Run targeted tests and typecheck**

Run:

```powershell
npm test -- tests/comparative-index.test.ts tests/city-search-query.test.ts tests/city-detail-query.test.ts
npm run typecheck
```

Expected: targeted tests pass and TypeScript reports no contract mismatches.

### Task 5: Search, Comparison, Nearby, Map, and UI Provenance

**Files:**
- Modify: `src/server/national-map.ts`
- Modify: `src/server/nearby-city-search.ts`
- Modify: `src/client/city-search-ui.ts`
- Modify: `src/client/france-map-ui.ts`
- Modify: `src/client/nearby-map-ui.ts`
- Modify: `app/city-search-page.tsx`
- Modify: `app/city-comparison-table.tsx`
- Modify: `app/france-map.tsx`
- Modify: `app/nearby-cities-panel.tsx`
- Modify: `app/nearby-cities-map.tsx`
- Modify: `tests/city-search-ui.test.ts`
- Modify: `tests/france-map-ui.test.ts`
- Modify: `tests/nearby-map.test.ts`
- Modify: `tests/nearby-city-search.test.ts`
- Modify: `tests/national-map.test.ts`

**Interfaces:**
- Search, comparison, nearby and map index summaries expose the new historical count and oldest source year through the shared `ComparativeIndex` type.
- Map category values and coloring remain based on target-year published observations; only the overall index gains temporal fallback.
- UI labels distinguish “Données communales [année]”, “Données communales complétées par l’historique”, “Partiellement estimé”, “Entièrement estimé” and “Indisponible”; category detail/tooltips identify the used source year.

- [x] **Step 1: Add failing UI/API contract tests**

Extend search, comparison, nearby and national-map fixtures with historical-only and mixed historical/department components. Assert API mappers preserve counts and oldest year, UI uses the precise provenance labels, and map category layers still gray target-year `ndiff` rows even when the overall index has a historical component.

- [x] **Step 2: Run targeted tests and confirm failures**

Run: `npm test -- tests/city-search-ui.test.ts tests/france-map-ui.test.ts tests/nearby-map.test.ts tests/nearby-city-search.test.ts tests/national-map.test.ts`

Expected: FAIL on missing historical provenance/count fields and labels; existing target-year category-map assertions remain unchanged.

- [x] **Step 3: Thread historical index metadata through API and UI**

Update the map/nearby/search mappers and renderers to preserve the aggregate metadata. Update shared provenance labels and explanatory text to say that the index uses the most recent published communal rate no older than N-3 before the target-year department complement. Keep raw category rates, category color source and historical chart observations untouched.

- [x] **Step 4: Run targeted tests and typecheck**

Run:

```powershell
npm test -- tests/city-search-ui.test.ts tests/france-map-ui.test.ts tests/nearby-map.test.ts tests/nearby-city-search.test.ts tests/national-map.test.ts
npm run typecheck
```

Expected: all targeted tests pass and public payload types remain consistent.

### Task 6: Environmental Risk Provenance

**Files:**
- Modify: `src/server/environmental-risk.ts`
- Modify: `src/server/city-detail.ts`
- Modify: `src/server/national-map.ts`
- Modify: `src/server/nearby-city-search.ts`
- Modify: `src/client/environmental-risk-ui.ts`
- Modify: `app/environmental-risk-section.tsx`
- Modify: `app/france-map.tsx`
- Modify: `app/nearby-cities-map.tsx`
- Modify: `tests/environmental-risk.test.ts`
- Modify: `tests/environmental-risk-ui.test.ts`

**Interfaces:**
- `EnvironmentalNeighborRow` carries the comparative-index provenance and oldest component source year for each scored neighbor.
- `EnvironmentalRiskSummary.provenance` distinguishes `published-only`, `historical-published`, `partially-estimated`, `estimated-only`, and `unavailable`.
- `EnvironmentalRiskSummary` adds current-only, historically supplemented, partially estimated and estimated-only contributor counts plus `oldestSourceYear`; the spatial weighting formula and coverage threshold do not change.

- [x] **Step 1: Add failing environmental summary/query tests**

Cover a radius with current-only, historical-only, mixed, estimated-only and unavailable neighbor indices; assert the weighted value is unchanged, the five aggregate provenance states are correct, the four contributor counts are correct, oldest source year is the minimum among scored neighbors, and unavailable neighbors do not affect that year or value.

- [x] **Step 2: Run environmental tests and verify failures**

Run: `npm test -- tests/environmental-risk.test.ts tests/environmental-risk-ui.test.ts`

Expected: FAIL because environmental query rows, summary contract and UI do not yet carry historical source metadata.

- [x] **Step 3: Propagate source metadata without changing spatial math**

Select comparative-index provenance and `oldest_exposure_source_year` with neighbor scores in both environmental SQL builders. Extend `summarizeEnvironmentalRisk` to classify all-current, historically supplemented, mixed/estimated and all-estimated neighborhoods. Update `src/client/environmental-risk-ui.ts` and `app/environmental-risk-section.tsx` with explicit French labels and contributor counts, without including unscored neighbors or changing their contribution to spatial weighting.

- [x] **Step 4: Run environmental tests**

Run: `npm test -- tests/environmental-risk.test.ts tests/environmental-risk-ui.test.ts`

Expected: PASS; all existing weighted-score and coverage assertions remain identical.

### Task 7: Migration, Official Backfill, and End-to-End Validation

**Files:**
- Modify: `scripts/test_database_schema.ps1`
- Modify: `scripts/test_comparative_index_v2.ps1`
- Modify: `scripts/test_backfill_ssmsi_history.ps1`
- Modify: `docs/imports-annuels.md`

**Interfaces:**
- No new API shape is introduced here. Validation uses the active snapshot and existing search, detail, nearby, map and environmental endpoints.
- The local official backfill changes only SSMSI source years 2016–2024; year 2025 is checked against a pre-run fingerprint and must match exactly afterward.

- [x] **Step 1: Verify the migration on a fresh and upgraded database**

Run: `pwsh -NoProfile -File scripts/test_database_schema.ps1`

Expected: migration 009 is registered exactly once on fresh and upgrade paths; all additive columns/views exist and raw-table definitions are unchanged.

- [x] **Step 2: Run the 2016–2024 backfill against the local official source**

Before import, record a deterministic fingerprint of every 2025 `crime_stats` row, including raw statistics, source, batch ID and `imported_at`. Run `pwsh -NoProfile -File scripts/backfill_ssmsi_history.ps1`. The fixture integration test replays this exact importer/backfill path twice to prove idempotence without repeating a costly five-million-row official load. Assert the fingerprint is unchanged, 2016–2024 rows and per-year batches exist, and the active snapshot contains the new version.

- [x] **Step 3: Compare representative communes and source provenance**

Query the active snapshot for all six categories for Nivillers (`60461`), Porta (`66146`), Norrois (`51406`), Villegongis (`36242`) and Beauvais (`60057`) for 2025. Record each selected `source_year`, source, effective rate, normalized score and aggregate count. Confirm Nivillers uses its published communal 2024 categories before the 2025 department complements, Beauvais remains six current-year published components, and no commune uses data earlier than 2022 for its 2025 index. Reconcile score deltas with the fallback policy; attribute source revisions only when verified.

- [x] **Step 4: Run the full verification set**

Run:

```powershell
npm test
npm run typecheck
npm run build
pwsh -NoProfile -File scripts/test_comparative_index_v2.ps1
pwsh -NoProfile -File scripts/test_import_crime_data_ssmsi.ps1
pwsh -NoProfile -File scripts/test_backfill_ssmsi_history.ps1
```

Expected: all commands exit 0. Then exercise search, commune detail, comparison, nearby map, France choropleth and environmental layer for 2025; confirm raw masked values stay “Non publié”, history only changes the derived overall index, the three-component minimum creates gray only when genuinely insufficient, and target-year category maps do not borrow historical values.

**Execution results:** the local database is on migration 009 with snapshot 11. The 2025 row count remains 523,125 and its fingerprint is unchanged (`baec9fba12dc6711101149da2e52a732`). Each historical SSMSI year has 523,125 rows across 34,875 communes and one SSMSI batch. Score deltas come from published historical rates taking precedence over the target-year department complements, not from changes to 2025 raw data; Nivillers rises from a target-year-only 25.8 to 49.4 because its 2024 published destruction and violence rates normalize to 100 each. Representative source-by-category details and score changes are recorded in `.superpowers/sdd/2026-10-10-temporal-ssmsi-exposure-fallback/progress.md`. Live API checks passed for search, commune detail, nearby, region-level map, commune-boundary map, and environmental risk. That local check exposed and led to a fix for numeric-string indices in the commune environmental summary; the full test/typecheck/build and all four database/import integration scripts now pass.

---

## Plan Self-Review

- **Spec coverage:** exact N-to-N-3 selection, target-year complement fallback, minimum coverage, X=10 semantics, 2016–2024 idempotent backfill, dynamic geography headers, raw-data preservation, per-component provenance, UI labels, map semantics, environmental propagation, representative communes, and full verification are assigned to Tasks 1–7.
- **Step scan:** each task writes tests before implementation and gives concrete commands and expected results; the only irreversible-looking local data operation is an idempotent year-scoped import with a pre/post 2025 fingerprint.
- **Type consistency:** SQL names flow as `source_year`, `component_source`, `effective_rate_per_1000`, `historical_published_basket_category_count`, `historical_availability_mask`, and `oldest_exposure_source_year`; API names are `exposureSourceYear`, `exposureProvenance`, `exposureRatePer1000`, `exposureScore`, `historicalPublishedComponentCount`, and `oldestSourceYear`.
- **Review focus:** the five most likely semantic regressions each have an explicit SQL or importer assertion in Tasks 1–2; environmental aggregation and display have their own tests in Task 6.
- **Proportion:** tasks follow the existing migration/import/snapshot/API boundaries and avoid changing raw comparison history or category-map semantics.

No commit is part of this plan.
