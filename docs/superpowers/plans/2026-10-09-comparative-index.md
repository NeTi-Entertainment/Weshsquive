# Comparative Index Implementation Plan

**Goal:** Replace the misleading cross-category global ranking with published-data metrics and one stable, coverage-aware comparative index.

**Architecture:** Add database views that choose one latest source row per city/year/category, calculate publication coverage, and rank a fixed six-category basket within population and availability cohorts. Search, city detail, and nearby search consume the same derived view; the official `crime_stats` rows stay unchanged.

**Tech Stack:** PostgreSQL/PostGIS, Next.js, TypeScript, React, Zod.

**Spec:** `docs/superpowers/specs/2026-10-09-comparative-index-design.md`

## Global Constraints

- Basket version: `residential-risk-v1`.
- Basket: burglary, vehicle theft, thefts from vehicles, intentional damage, non-domestic physical violence, drug trafficking.
- Minimum coverage: 3 of 6 categories.
- Minimum cohort size: 50 cities.
- A cohort uses year, year-specific population band, and exact category availability mask.
- A masked category is never imputed as zero or given a synthetic category rate.
- Colors apply only to the comparative index; nearby results reuse the same city/year index.
- No commits.

## Review Focus

- Cities with only masked categories return no index and null published totals.
- True published zero rates remain zero and can receive a valid comparative rank.
- Historical years use population available at or before that year.
- Search, detail, and nearby return identical index metadata for a city/year.
- Out-of-radius filters do not change a city's index or color.

### Task 1: Shared Derived Metrics

**Files:** Create `db/migrations/002_comparative_index_views.sql`; create `src/server/comparative-index.ts`.

Add a category-level latest-source view and a city/year view exposing published totals, overall publication coverage, six-category availability, population band, cohort size, index, status, and confidence. Export the fixed basket metadata and shared response types from TypeScript.

### Task 2: Search API and Main Table

**Files:** Modify `src/server/city-search.ts`, `app/api/cities/search/route.ts`, `src/client/city-search-ui.ts`, and `app/city-search-page.tsx`.

Use year-specific population and shared derived metrics. Rename global totals/rates as published totals/partial rates; add coverage and index filters/sorting. Remove percentile/color from partial rates and color only the index cell.

### Task 3: City Detail and History

**Files:** Modify `src/server/city-detail.ts`, `app/communes/[inseeCode]/page.tsx`, and `app/api/cities/[inseeCode]/route.ts`.

Return the same comparative index and published metrics as search. Label territory aggregates as partial, remove their implied overall ranking, and show coverage in the yearly history.

### Task 4: Nearby Search

**Files:** Modify `src/server/nearby-city-search.ts`, `src/client/nearby-cities-ui.ts`, `app/api/cities/[inseeCode]/nearby/route.ts`, and `app/nearby-cities-panel.tsx`.

Join the shared city/year metrics view; filter by partial rate or index explicitly. Remove radius-local percentile ranking and render the stable comparative index, coverage, and confidence.

### Task 5: UI Styling and Verification

**Files:** Modify `app/globals.css` and the implementation files above as needed.

Run TypeScript validation and read-only API/SQL checks for representative cities with full, partial, insufficient, and published-zero data. Confirm migration idempotency and that source rows are unchanged.
