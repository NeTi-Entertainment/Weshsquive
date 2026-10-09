# SDD ledger — plan: docs/superpowers/plans/2026-10-09-environmental-risk.md

## Setup

Ruling: this workspace has no Git repository, native worktree, or existing attached worktree; user explicitly disallows commits — use one coding agent at a time in the shared directory, retain pre-task copies of every touched file, and review a generated before/after diff package — cost if wrong: no Git-based rollback or exact historical diff, mitigated by preserved task snapshots and sequential edits.

## Preflight Interface Scan

| Pair / task | Shared interface or self-consistency check | Result |
|---|---|---|
| Task 1 → Task 2 | `CityDetail.environmentalRisk: EnvironmentalRiskSummary[]` feeds the detail section | Consistent; Task 2 consumes Task 1's exact type |
| Task 1 → Task 3 | `buildMapEnvironmentalRiskQuery`, `summarizeEnvironmentalRisk`, radius/status/summary types | Consistent; Task 3 adds optional batch API behavior using the produced server contract |
| Task 1 → Task 3 | Both touch `src/server/environmental-risk.ts` | Sequential dependency; Task 3 only extends the Task 1 module |
| Task 1 → Task 3 | Detail and map both bind year and snapshot ID | Consistent; each query receives explicit values rather than rereading a potentially changed active snapshot |
| Task 3 → Task 4 | `environmentalRadiusKm` request parameter and `NearbyMapPoint.environmentalRisk` | Consistent; Task 4 selects the radius and renders the batch response |
| Task 2 → Task 4 | Both may touch `app/globals.css` | Distinct section/map classes; execute sequentially and keep styling scoped |
| Task 1 self-check | Tests cover weight, origin exclusion, null indices, thresholds, coordinates, SQL year/snapshot; files and interfaces align | Consistent |
| Task 2 self-check | Helper tests align with four statuses, null display, coverage and detail section | Consistent |
| Task 3 self-check | Optional radius leads to one batch query, snapshot from initial response, and filter-independent neighbor set | Consistent |
| Task 4 self-check | Four explicit environmental criteria, selected-radius request, gray unavailable markers, popup coverage | Consistent |

## Task Reports

Task 1: Ruling: preserve the minimum of three scored neighbors and change the weighted-result example to three valid neighbors yielding exactly 40 — the approved spec requires at least three inputs for an exposed score, so the test must exercise the formula inside that valid state — cost if wrong: the test no longer demonstrates the arithmetic with only two terms, though it still proves the formula at the minimum supported coverage.

Task 1: complete (no commit; focused tests 16/16, full suite 61 passed/1 skipped, typecheck and build passed; task review approved).

Task 1: minor (resolved): the original 50% boundary case did not distinguish weighted coverage from row-count coverage; the final-review test-only follow-up added contrasting non-zero-distance cases and received scoped approval.

Task 2: complete (no commit; 4 targeted tests, full suite 65 passed/1 skipped, typecheck and build passed; task review approved with no findings).

Task 3: Ruling: omit `app/api/cities/[inseeCode]/nearby/route.ts` from the file list because it already forwards parsed query parameters and spreads the returned search result into JSON; add the map-point response type to Task 3 so Task 4 consumes a defined contract — the server search parser and result mapper own the behavior, while the route remains generic — cost if wrong: route-specific behavior would lack a direct code change, covered instead by parser/search contract tests and the existing generic response spread.

Task 3: complete (no commit; focused tests 9/9, full suite 69 passed/1 skipped, typecheck and build passed; task review approved with no findings).

Task 4: Ruling: add a focused `buildNearbySearchUrl` test for selected environmental radius serialization and omission in default mode — the approved interface requires the selected radius to reach the API, which the original Task 4 test list checked only at the marker-color layer — cost if wrong: a query-string regression could escape map-color tests; the added test directly pins that UI/server contract.

Final review: Ruling: address the P3 weighted-coverage finding with contrasting test cases only; the source calculation already uses distance weights — cost if wrong: a row-count-only regression could otherwise pass the threshold tests.

Task 4: complete (no commit; 14 focused tests, full suite 81 passed/1 skipped, typecheck and build passed; task review approved with no findings).

Final review: P3 coverage-test finding addressed by a tests-only follow-up; scoped re-review approved with no regression.

Overall final review: complete; no open findings. Local PostGIS query plans and API timings were checked; the default nearby path stays separate from the optional environmental batch.


