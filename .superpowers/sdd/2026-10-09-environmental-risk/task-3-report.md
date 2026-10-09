# Task 3: Batch Environmental Summaries for Nearby Map Points

## Result

Implemented optional environmental summaries on nearby-search map points. The nearby API accepts `environmentalRadiusKm` values 25, 50, 100, or 200. When enabled, the search takes the active `snapshot_id` from its initial query and uses it with the requested year and unique map-point INSEE codes for one batch call to `buildMapEnvironmentalRiskQuery`.

Batch rows are grouped per target and passed to the shared `summarizeEnvironmentalRisk` implementation. Null comparative indices remain null and therefore contribute to the denominator and coverage, never as zero. The target commune is excluded by the shared SQL/summarizer contract. Environmental neighbors are fetched independently of nearby display filters and pagination.

Every returned map point has `environmentalRisk`: a summary when a batch ran and a matching target row was returned, otherwise `null`. With no requested radius, no map points, or no active snapshot ID, no environmental query runs. The snapshot ID is not included in `NearbyCitySearchResult`.

## Files Changed

- `src/server/nearby-city-search.ts`: validates the optional radius, returns the active snapshot internally, performs and groups the single batch query, and enriches map points.
- `src/client/nearby-map-ui.ts`: adds the optional `EnvironmentalRiskSummary | null` map-point contract.
- `tests/nearby-city-search.test.ts`: covers invalid radius, unique-code batching, exact year/snapshot/radius propagation, empty paginated results, filter independence, null-index coverage, default behavior, no map points, and missing snapshot.

The generic route handler was not modified. No migration, persistent storage, repository metadata, branch, worktree, or commit was created.

## TDD Evidence

The focused tests were added and run before production changes. They failed because `environmentalRadiusKm` was rejected by the strict schema and the default response did not set `environmentalRisk: null`. After implementation, the same focused command passed.

## Verification

- `npm test -- --reporter=verbose tests/nearby-city-search.test.ts`: **9 passed**.
- `npm test`: **69 passed, 1 skipped** across 11 test files (1 test file skipped).
- `npm run typecheck`: passed.
- `npm run build`: passed; Next.js compiled and generated routes successfully.

## Limits

The tests validate generated SQL, query arguments, grouping, and summaries using mocked database results. No live PostgreSQL/PostGIS execution, spatial-index plan, or local performance measurement was performed in this task.
