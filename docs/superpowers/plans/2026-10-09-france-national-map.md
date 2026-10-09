# France National Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax. No commits are to be created, per user instruction.

**Goal:** Add an interactive map of France that navigates from regions to departments to visible commune points without rendering off-screen communes or inventing territory-level crime statistics.

**Architecture:** Add a validated map API backed by PostGIS and the active metrics snapshot. It returns navigation-only region or department groups at low zoom, then only commune points in the current viewport at close zoom; the existing Leaflet stack renders the appropriate layer. Add a map/table switch in the main search page and reuse current statistical color and environmental-risk calculations for commune points.

**Tech Stack:** Next.js App Router, TypeScript, PostgreSQL/PostGIS, Leaflet/react-leaflet, Vitest.

**Spec:** `docs/superpowers/specs/2026-10-09-france-national-map-design.md`

## Global Constraints

- The database continues to store official SSMSI observations separately from derived indices and display colors.
- Region and department groups are geographic navigation markers only; they expose no crime totals, averages, indices, or risk colors.
- Commune markers use existing commune-center coordinates and the active metrics snapshot.
- Missing or unpublished values remain unavailable and gray; they are never converted to zero.
- The map uses OpenStreetMap tiles and does not add paid map services or administrative polygons.
- Do not create a commit.

## Review Focus

- Invalid, reversed, out-of-range, or antimeridian-crossing map bounds must be rejected or normalized without returning an accidental whole-country result.
- Rapid pan/zoom requests must not let an old response overwrite the newest viewport.
- Selecting a region or department must preserve indicator/year filters and must not imply a statistical aggregation.
- Category percentiles must use published observations with the same year, population band, count unit, and rate denominator, independent of viewport.
- Environmental values must use one snapshot and one batch query for visible commune targets; they must not be computed for region or department groups.

---

### Task 1: Map Query Contract and PostGIS Service

**Files:**
- Create: `src/shared/map-levels.ts`
- Create: `src/server/national-map.ts`
- Create: `tests/national-map.test.ts`

**Interfaces:**
- `src/shared/map-levels.ts` produces `getNationalMapLevel(zoom): "region" | "department" | "commune"` and the shared zoom thresholds.
- `src/server/national-map.ts` produces `parseNationalMapParams(params: URLSearchParams): NationalMapParams`, `buildNationalMapQuery(params: NationalMapParams): SqlQuery`, and `searchNationalMap(db: Queryable, params: NationalMapParams): Promise<NationalMapResult>`.
- `NationalMapParams` contains year, zoom, west/south/east/north bounds, criterion (`comparativeIndex`, `categoryRate`, or `environmentalRisk`), optional map category code, optional region/department/commune filters, population bounds, comparative-index bounds, optional filter category and its incident/rate bounds, and optional environmental radius.
- `NationalMapResult` contains `level: "region" | "department" | "commune"`, the active snapshot ID, and a discriminated array of navigation groups or commune points.
- Use region groups through zoom 5, department groups at zoom 6-7, and commune points from zoom 8. Keep thresholds exported as constants.

- [ ] **Step 1: Write failing parser and hierarchy tests**
  - Assert zoom 5 selects `region`, zoom 6 and 7 select `department`, and zoom 8 selects `commune`.
  - Assert malformed bounds, unsupported criteria, and invalid environmental radii are rejected.
- [ ] **Step 2: Run the focused test and confirm expected failures**

Run: `npm test -- --reporter=verbose tests/national-map.test.ts`

Expected: FAIL because `src/server/national-map.ts` does not yet exist.

- [ ] **Step 3: Implement strict parameter parsing and query construction**
  - Parameterize all SQL values.
  - For region/department levels, return only navigation fields, group counts, and group bounds derived from member commune centers; do not join crime metric values into the group result.
  - At commune level, filter `cities.geom` to the requested bounding box and join active-snapshot metrics for the requested year.
  - Calculate category color percentiles over the full matching national comparison cohort before applying the viewport filter. Keep unit, denominator, publication, and population-band restrictions identical to the current map category ranking.
- [ ] **Step 4: Add service mapping and focused service tests**
  - Assert a Bordeaux-sized viewport excludes a test commune outside the bounds.
  - Assert the query is snapshot-bound and uses published category values only.
  - Assert region/department results contain no crime metric fields.
- [ ] **Step 5: Run the focused tests and confirm they pass**

Run: `npm test -- --reporter=verbose tests/national-map.test.ts`

Expected: all new query and service tests pass.

### Task 2: API and Visible Environmental Batch

**Files:**
- Create: `app/api/cities/map/route.ts`
- Modify: `src/server/national-map.ts`
- Modify: `tests/national-map.test.ts`

**Interfaces:**
- API endpoint: `GET /api/cities/map`.
- Consumes `parseNationalMapParams` and `searchNationalMap` from Task 1.
- For environmental mode, call `buildMapEnvironmentalRiskQuery` once with unique visible commune codes, year, the map query's snapshot ID, and selected radius. Apply `summarizeEnvironmentalRisk` to those batch results and attach summaries to commune points only.

- [ ] **Step 1: Add failing tests for environmental batch and API errors**
  - Assert environmental queries do not run for group levels or when no communes are visible.
  - Assert a visible commune batch uses unique codes, the exact snapshot ID, and the requested year/radius.
  - Assert invalid query parameters return HTTP 400 and valid queries return the map contract.
- [ ] **Step 2: Run the focused tests and confirm expected failures**

Run: `npm test -- --reporter=verbose tests/national-map.test.ts`

Expected: FAIL because the API and environmental integration are missing.

- [ ] **Step 3: Implement the route and batched environmental enrichment**
  - Keep environmental queries bounded to visible commune targets and reuse the existing risk summarizer; do not perform one query per point.
  - Preserve explicit null/insufficient-coverage statuses.
- [ ] **Step 4: Run the focused tests and confirm they pass**

Run: `npm test -- --reporter=verbose tests/national-map.test.ts`

Expected: all API and environmental batch tests pass.

### Task 3: Map State, URL, and Zoom Behavior

**Files:**
- Create: `src/client/france-map-ui.ts`
- Create: `tests/france-map-ui.test.ts`
- Reuse: `src/client/latest-request.ts`

**Interfaces:**
- Produces `buildNationalMapUrl(params, bounds, zoom, criterion): string` and small mapping helpers for API response parsing. Imports `getNationalMapLevel` from `src/shared/map-levels.ts`.

- [ ] **Step 1: Write failing tests for URL construction and level changes**
  - Assert current year, all active search filters, selected map indicator/category, viewport bounds, and zoom are serialized; omit category thresholds when no filter category is selected.
  - Assert zoom changes trigger a level change at the defined thresholds and preserve the chosen indicator.
- [ ] **Step 2: Run the focused test and confirm expected failures**

Run: `npm test -- --reporter=verbose tests/france-map-ui.test.ts`

Expected: FAIL because the map UI helpers do not exist.

- [ ] **Step 3: Implement the URL and zoom helpers**
- [ ] **Step 4: Run the focused tests and confirm they pass**

Run: `npm test -- --reporter=verbose tests/france-map-ui.test.ts`

Expected: all map state tests pass.

### Task 4: National Leaflet Map

**Files:**
- Create: `app/france-map.tsx`
- Modify: `app/globals.css`
- Create or extend: `tests/france-map-component.test.ts`

**Interfaces:**
- `FranceMap` accepts year, geographic filters, available categories, selected indicator/category, and callbacks to synchronize search filters.
- Uses the Task 2 API and Task 3 URL/hierarchy helpers.
- Uses existing color selection from `src/client/nearby-map-ui.ts` for commune points; group markers are neutral and have no statistical color.

- [ ] **Step 1: Add failing rendering tests for each map level**
  - Region and department groups show names/counts and zoom affordances, not risk colors or statistics.
  - Commune markers use the selected indicator color; unavailable values use the existing gray color.
  - Environmental mode shows risk value/coverage only on commune popups.
- [ ] **Step 2: Run the focused tests and confirm expected failures**

Run: `npm test -- --reporter=verbose tests/france-map-component.test.ts`

Expected: FAIL because the national map component does not exist.

- [ ] **Step 3: Implement the Leaflet map component**
  - Render OSM tiles with attribution and fit the initial view to metropolitan France.
  - Recenter on selected overseas regions instead of fitting all separated territories into one viewport.
  - Debounce `moveend` requests, use `LatestRequest` cancellation/current-request checks, and update only visible layers.
  - Clicking a region/department fits its returned bounds; clicking a commune links to its detail page.
  - Render regional/dept group counts as navigation counts only. Use existing official category values and methodology labels in commune popups.
- [ ] **Step 4: Run focused component tests and confirm they pass**

Run: `npm test -- --reporter=verbose tests/france-map-component.test.ts`

Expected: map-level and marker-state tests pass.

### Task 5: Main Search View Integration

**Files:**
- Modify: `app/city-search-page.tsx`
- Modify: `src/client/city-search-ui.ts` only if shared filter serialization needs a helper
- Modify: `app/globals.css`
- Modify: `tests/city-search-ui.test.ts` or create `tests/france-map-page.test.ts`

**Interfaces:**
- Adds an accessible segmented view switch, `Tableau` / `Carte`, to the existing main page.
- The map receives the submitted year and filters; switching views preserves search inputs and selected indicator/category.

- [ ] **Step 1: Add failing UI tests for switching views and filter preservation**
  - Assert the map view is reachable from the main search page.
  - Assert switching to map preserves year, all active search filters, and selected map criterion; switching back preserves table filters.
- [ ] **Step 2: Run focused tests and confirm expected failures**

Run: `npm test -- --reporter=verbose tests/france-map-page.test.ts`

Expected: FAIL because the main page has no map mode.

- [ ] **Step 3: Integrate the map view and responsive controls**
  - Keep the current table and comparison behavior intact.
  - Add the criteria selector and legend for the map without nesting cards or obscuring the viewport.
- [ ] **Step 4: Run focused tests and confirm they pass**

Run: `npm test -- --reporter=verbose tests/france-map-page.test.ts`

Expected: all view-switching tests pass.

### Task 6: Full Verification and Local Walkthrough

**Files:**
- No new production files; adjust earlier tasks only if verification exposes a defect.

- [ ] Run `npm test -- --reporter=dot` and confirm there are no failures.
- [ ] Run `npm run typecheck` and confirm exit code 0.
- [ ] Run `npm run build` and confirm exit code 0.
- [ ] Exercise `/api/cities/map` at zoom levels 5, 6, 8 and check region, department and commune responses against the local database if available.
- [ ] Open the app and visually verify France, department and Bordeaux-level views on desktop and mobile; confirm the Bordeaux viewport does not request/render Marseille.
- [ ] Record any unavailable database/browser check as unverified rather than inferring success from unit tests.
