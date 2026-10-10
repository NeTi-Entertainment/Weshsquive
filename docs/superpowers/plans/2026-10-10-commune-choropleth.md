# Choroplèthe des communes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Color visible commune surfaces on the national map using the existing selected indicator, without changing statistical values or coloring administrative groups with invented aggregates.

**Architecture:** Import validated commune MultiPolygons into a separate PostGIS geometry column, preserving the existing centroid point. Extend the map API to return only viewport-intersecting, zoom-simplified commune features under a 2,500-feature limit, then render those features as clickable Leaflet polygons using current metric styles and popups.

**Tech Stack:** Next.js App Router, TypeScript, PostgreSQL/PostGIS, PowerShell import scripts, Leaflet/react-leaflet, Vitest.

**Spec:** `docs/superpowers/specs/2026-10-10-commune-choropleth-design.md`

## Global Constraints

- Communes are the only statistically colored administrative unit.
- Region and department markers remain neutral navigation-only items.
- A masked SSMSI value remains masked, and missing values remain unavailable/gray.
- The existing point geometry and all crime, environment, proximity, and property metrics remain unchanged.
- No paid map service is added.
- No commit is created.

## Review Focus

- A commune polygon crossing the viewport edge must be returned even when its centroid is off-screen; test the spatial intersection query.
- A failed or incomplete boundary import must not replace the current complete set; test the coverage guard and transaction rollback.
- A viewport with too many features must request more zoom rather than silently omit communes; test the 2,500-feature threshold.
- Simplification must preserve valid MultiPolygon topology and never alter the stored boundary; test query contract and PostGIS geometry validity.
- Geometry without a metric, masked crime data, and an unavailable metric must remain distinguishable in polygon style and popup; test all current criterion style mappings.
- An older viewport response must not replace the newest polygon layer; retain the map's `LatestRequest` cancellation behavior and its existing unit coverage.

---

### Task 1: Store and Import Commune Boundaries

**Files:**
- Create: `db/migrations/007_city_boundaries.sql`
- Create: `scripts/import_city_boundaries.ps1`
- Create: `scripts/test_import_city_boundaries.ps1`
- Modify: `scripts/test_database_schema.ps1`
- Modify: `scripts/update_official_data.ps1`

**Interfaces:**
- Schema adds nullable `cities.boundary_geom geometry(MultiPolygon, 4326)` and a GiST index; `cities.geom`, latitude, and longitude are untouched.
- Import script accepts the existing database connection parameters plus optional `SourceYear` and `SourceUrl`; default source queries official commune contour GeoJSON by department.
- Import succeeds only when at least 90% of currently known communes have one valid, non-empty polygon; duplicate codes, invalid geometry, empty source, or lower coverage abort the transaction and do not mark the batch complete.
- The annual official-data workflow refreshes contours immediately after refreshing the administrative commune list and centers.

- [x] **Step 1: Write failing schema and importer integration tests**
  - Assert the migration creates a nullable MultiPolygon column with SRID 4326 and a GiST index while retaining existing point geometry.
  - With test GeoJSON fixtures, assert valid code-matched polygons import and re-import without duplicates; assert empty, malformed, duplicate, invalid, and below-90%-coverage sources fail without a completed import batch or partial geometry write.
- [x] **Step 2: Run the focused integration test and verify it fails for the missing migration/importer**

Run: `pwsh -NoProfile -File scripts/test_import_city_boundaries.ps1`

Expected: FAIL because migration and importer do not exist.

- [x] **Step 3: Add the additive PostGIS migration**
  - Use `geometry(MultiPolygon, 4326)` and a dedicated GiST index; do not alter the point `geom` column or coordinate trigger.
- [x] **Step 4: Implement the idempotent, all-or-nothing importer**
  - Fetch official `format=geojson&geometry=contour` data in department-sized batches, validate feature codes and polygons, then stage the complete validated payload before one SQL transaction updates known city rows and records the completed source batch.
  - Use PostGIS validation and reject invalid geometries rather than silently repairing their official coordinates.
- [x] **Step 5: Add the boundary importer to the annual geography refresh**
  - Invoke `import_city_boundaries.ps1` after the administrative-area and coordinate imports when the annual workflow refreshes geography; log it as a distinct step and pass the same database parameters and geography source year.
- [x] **Step 6: Run integration and schema tests**

Run: `pwsh -NoProfile -File scripts/test_import_city_boundaries.ps1`

Expected: migration, coverage, rollback, re-import, and point-preservation assertions all pass.

### Task 2: Return Viewport-Only Simplified Polygons

**Files:**
- Modify: `src/server/national-map.ts`
- Modify: `tests/national-map.test.ts`
- Modify: `tests/cities-map-route.test.ts` for the changed commune response contract
- Modify: `app/api/cities/map/route.ts` only if the new response status requires a route adjustment

**Interfaces:**
- Add `NationalMapCommune` with the current commune metric fields plus a GeoJSON `MultiPolygon` geometry.
- Change the commune-level result to `{ level: "commune", snapshotId, groups: [], communes: NationalMapCommune[], requiresZoom: boolean }`; group-level results remain navigation-only.
- Export `NATIONAL_MAP_MAX_COMMUNE_FEATURES = 2500`; `requiresZoom` is true and `communes` is empty when the viewport contains more than that many polygons.
- Commune selection uses `ST_Intersects(boundary_geom, ST_MakeEnvelope(west, south, east, north, 4326))`, with the geometry index; metric filters and snapshot behavior remain unchanged.
- Geometry simplification uses `ST_SimplifyPreserveTopology` on a projected copy in EPSG:3857, with tolerance `0.5 * 156543.03392 / 2^zoom` projected meters, then transforms the display geometry back to EPSG:4326. Stored geometry is never updated by map queries.

- [x] **Step 1: Add failing query and service tests**
  - Assert the query spatially intersects polygon boundaries rather than filtering by centroid, selects geometry through the GiST-friendly boundary column, simplifies only the returned geometry, and retains the active metrics snapshot.
  - Assert the 2,500-feature limit returns `requiresZoom` with no partial commune list, while 2,500 or fewer returns all qualifying communes.
  - Assert group-level requests do not return polygons or statistical group values.
- [x] **Step 2: Run `npm test -- tests/national-map.test.ts` and verify the new tests fail**
- [x] **Step 3: Implement the polygon result type and PostGIS query**
  - Keep centroid coordinates on commune metric objects for the environmental batch query; use boundary geometry only for rendering and viewport intersection.
  - Preserve existing category percentiles, market selections, filters, and snapshot binding.
- [x] **Step 4: Run `npm test -- tests/national-map.test.ts`**

Expected: the focused map service tests pass, including the feature-limit and off-center intersection cases.

### Task 3: Render Clickable Commune Choropleth

**Files:**
- Modify: `app/france-map.tsx`
- Modify: `src/client/france-map-ui.ts` for commune counts and feature-geometry or limit-state helpers
- Modify: `tests/france-map-ui.test.ts`
- Modify: `tests/national-map.test.ts` for response mapping coverage

**Interfaces:**
- Replace the commune `CircleMarker` layer with one React-Leaflet `Polygon` per GeoJSON MultiPolygon; keep group navigation markers unchanged.
- Convert GeoJSON `[longitude, latitude]` coordinates to Leaflet `[latitude, longitude]` positions while preserving exterior rings, holes, and polygon parts.
- Use `getNationalMapFeatureVisualStyle` and `getNationalMapFeatureColor` with the same metric fields currently used by commune points.
- A polygon click exposes the existing commune popup and links to `/communes/{inseeCode}?year={year}`.
- When `requiresZoom` is true, show a concise map status requesting a closer zoom; do not draw centroid fallback markers.

- [x] **Step 1: Add failing UI/helper tests**
  - Test coordinate conversion for a MultiPolygon with a hole and multiple parts.
  - Test published, masked, missing, partially estimated, environmental, sale, and rent styles continue through the existing style helpers.
  - Test `requiresZoom` yields an explicit zoom prompt and no point fallback.
- [x] **Step 2: Run `npm test -- tests/france-map-ui.test.ts tests/national-map.test.ts` and verify the new tests fail**
- [x] **Step 3: Render commune polygons and preserve existing popup interactions**
  - Keep region/department controls, indicator selectors, loading/error states, and stale-request protection intact.
- [x] **Step 4: Run the focused UI and map tests**

Expected: commune polygons are clickable and all existing indicators retain their established colors and disclosure text.

### Task 4: Integrated Verification

**Files:**
- Modify tests only if integration exposes a regression in this feature.

**Interfaces:**
- No API or database changes beyond Tasks 1-3.

- [x] **Step 1: Run the full automated checks**

Run: `npm test`

Expected: all tests pass.

Run: `npm run typecheck`

Expected: TypeScript exits successfully.

Run: `npm run build`

Expected: Next.js production build succeeds.

- [x] **Step 2: Apply the migration, import contours, and inspect coverage locally**

Run: `pwsh -NoProfile -File scripts/apply_migrations.ps1`

Run: `pwsh -NoProfile -File scripts/import_city_boundaries.ps1`

Expected: schema migration succeeds; imported distinct valid boundaries meet the 90% known-commune coverage guard; point coordinate counts/checksums remain unchanged.

- [x] **Step 3: Verify the running app at France, department, and commune zooms**
  - Confirm broad levels retain neutral navigation markers, commune zoom fills visible boundaries, a pan away does not render off-screen towns, missing/masked data remain accurately styled, and clicks open the correct commune/year.
  - Check a dense urban viewport and mobile width; when more than 2,500 communes intersect, confirm the explicit zoom prompt rather than partial rendering.
