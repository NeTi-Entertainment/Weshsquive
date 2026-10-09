# Final Fix Report

Updated only `tests/environmental-risk.test.ts`: the acceptance case now has 3/9 scored rows but exactly 50% weighted coverage, and a new case rejects 3/6 scored rows when near null-index neighbors reduce weighted coverage below 50%.

Focused test command: `npm test -- tests/environmental-risk.test.ts`

Exact output:

```text
> app-criminalite@0.1.0 test
> vitest run tests/environmental-risk.test.ts


 RUN  v5.0.3 C:/POCKETRATSTUDIO/AppCriminalite


 Test Files  1 passed (1)
      Tests  14 passed (14)
   Start at  15:39:12
   Duration  228ms (import 49%, transform 38%, tests 9%, worker 5%)
```

The saved pre-fix copy remains unchanged (SHA-256: `DF4E4192CE194BFFCBA507D23FFAF7D8EF46823A63BF92A97C60A64923860E45`).
