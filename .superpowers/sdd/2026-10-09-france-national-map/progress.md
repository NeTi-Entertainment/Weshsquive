# SDD ledger — plan: docs/superpowers/plans/2026-10-09-france-national-map.md

Setup: no Git metadata is present in the workspace; proceed in the current folder as requested, with no commits. The plan spec exists and is readable.

Pre-flight shared interfaces:
- Task 1 -> Task 2: `NationalMapResult` must expose the active snapshot ID and a discriminated region/department/commune payload; Task 2 consumes it for one environmental batch. Verified against both plan blocks.
- Task 1 -> Task 3/4: server payload level and map point metadata feed the client URL/layer; exact stable fields will be tested before integration.
- Task 2 -> Task 4: `/api/cities/map` returns the service payload plus environmental summaries on commune points only. Verified against plan blocks.
- Task 3 -> Task 4: `getNationalMapLevel` and `buildNationalMapUrl` determine request contract and layer level. Verified against plan blocks.
- Task 4 -> Task 5: `FranceMap` receives committed search filters and selected criterion; main-page switch preserves them. Verified against plan blocks.

Ruling: Execute in the current workspace rather than a Git worktree — the directory is not a Git repository and the user explicitly requested no commits — cost if wrong: this change is not isolated from other local edits.
Ruling: Apply all active population, comparative-index, commune-name, and category filters to commune points — the approved spec says the map reuses the current search filters, while the initial plan only listed geographic filters — cost if wrong: map and table could show different commune sets.
Ruling: Store zoom thresholds in `src/shared/map-levels.ts` and consume them on both client and server — a shared contract avoids the displayed layer and API payload disagreeing at transition zooms — cost if wrong: one small shared module is more structure than the feature needs.

Task 1: complete — `tests/national-map.test.ts` observed missing-module failure before implementation, then passed 16/16 tests; `npm run typecheck` passed after narrowing the group level.
Task 2: complete — API/environment tests observed missing-route and missing-batch failures before implementation, then passed 18/18 tests; typecheck passed.
Task 3: complete — `tests/france-map-ui.test.ts` observed missing-module failure before implementation, then passed 4/4 tests. Map URLs preserve active search filters, trim category thresholds when category is absent, and serialize bounds at five decimal places.
Ruling: Keep component/page verification at the browser level rather than add a DOM test stack for Leaflet — the project uses Vitest's Node environment and has no DOM test dependencies; pure UI/query helpers are automated and the map was exercised in the real app — cost if wrong: rendering regressions in browser-specific interactions are less likely to be caught automatically.

Task 4: complete — national Leaflet map rendered and exercised in the local browser at region, department, and commune zoom levels; OSM tiles, color legend, responsive mobile layout, and the visible commune layer were observed. The Bordeaux viewport API check returned only in-bounds communes and excluded Marseille. Automated helper/API tests cover shared color, unavailable states, counts, and map payload behavior; no DOM component harness is installed.
Task 5: complete — the accessible Tableau/Carte switch was exercised in the local browser; submitted filters and selected map criterion are wired through the parent view. Map state remains independent from table paging/comparison state. No DOM page test was added for the same harness limitation.
Task 6: complete — full suite `npm test -- --reporter=dot` passed (108 passed, 1 skipped); `npm run typecheck` and `npm run build` passed. Local API checks returned 13 regions, 96 departments, and 60 Bordeaux-area communes at the requested levels; all commune points were within bounds and Marseille was absent. Category-rate and environmental layers both returned 60 points on snapshot 1; the environmental sample was comparable with 151 neighbors. The browser showed OSM tiles and zoom-dependent region/department/commune layers, including a mobile viewport.

Final review: fresh read-only subagent review found no critical or important issues. Minor (deferred): the API accepts a valid but zoom-inconsistent wide bounding box, so a direct/non-Leaflet zoom-8 request could ask for all French communes; normal map-generated bounds stay viewport-sized, and adding a hard span limit risks rejecting legitimate large displays. Minor (deferred): pan/zoom/filter integration has browser/API verification but no automated component test because this repository has no DOM test harness. Reviewer did not inspect coordinates or run tests/browser; those were independently verified above.
