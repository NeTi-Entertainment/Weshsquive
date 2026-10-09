# Task 1 implementation report

## Status: COMPLETE

Implemented the shared environmental-risk calculation and integrated it into commune detail responses. No official statistics or persistent data were changed, and no migration or commit was created.

## Implementation

- Added `src/server/environmental-risk.ts` with the four supported radii, summary and neighbor types, the pure weighted summarizer, and parameterized PostGIS query builders for a single commune and a batch of map targets.
- The score uses `1 - distance / radius`, excludes the target commune and the strict radius boundary, and averages only non-null comparative indices. Missing indices remain in the weighted coverage denominator. A score is exposed only with at least three scored neighbors and at least 50% weighted coverage; otherwise its value is `null` with an explicit status.
- The city query evaluates all four radii, uses `ST_DWithin` for spatial-index filtering, and binds the requested year and snapshot. The batch map query binds the target codes, year, snapshot, and selected radius while retaining neighbors with missing comparative indices.
- Extended `CityDetail` with four environmental summaries. The detail flow runs its environmental query alongside history and comparisons, reusing the exact `snapshot_id` from the first detail row. Missing coordinates and empty neighborhoods keep all four radius entries with explicit statuses.
- Added focused unit, SQL-contract, and detail-snapshot tests.

## TDD and verification

- RED: before implementation, the targeted tests failed because `environmental-risk.ts` did not exist and `getCityDetail` issued three queries instead of four.
- GREEN: `npm test -- --reporter=verbose tests/environmental-risk.test.ts tests/city-detail-query.test.ts` — 2 test files passed, 16 tests passed.
- Full suite: `npm test -- --reporter=dot` — 9 files passed, 1 skipped; 61 tests passed, 1 skipped.
- `npm run typecheck` — passed.
- `npm run build` — passed; Next.js compiled and generated the app routes successfully.

## Review and limitations

- Self-review found no remaining issues in the changed calculation, SQL predicates, or snapshot propagation.
- A before/after diff package is available at `task-1-diff.patch`; pre-task copies of the two modified files remain in `task-1-before/`.
- SQL was verified through query-contract tests and the application build; this task did not execute the new queries against a live PostGIS database.
- No Git repository, branch, worktree, agent, or commit was created.
