# Comparative index design

## Objective

Separate official published statistics from a derived comparative index so that masked
categories never behave like zero and cities are not ranked from different statistical
coverage without that difference being accounted for.

The database remains the source of truth for official values. Coverage, cohorts,
percentiles, colors and the comparative index are derived at query time and are never
stored in `crime_stats`.

## Published metrics

The existing cross-category sum remains available as descriptive information only. It
is renamed in the API and interface to make its partial nature explicit:

- `publishedIncidentCount`: sum of published category counts;
- `partialRatePer1000`: that sum divided by the applicable reference population;
- `publishedCategoryCount`: number of all SSMSI categories published for the city-year;
- `totalCategoryCount`: number of categories expected for that year;
- `coverageRatio`: published categories divided by expected categories.

These values may be sorted and filtered, but they receive no percentile, color or
territorial ranking. A city with no published category receives `null` for the count and
rate. A city with published zeroes retains numeric zeroes.

## Fixed comparison basket

The application owns a versioned, fixed basket of six indicators selected for local and
residential exposure:

1. Cambriolages de logement
2. Vols de véhicule
3. Vols dans les véhicules
4. Destructions et dégradations volontaires
5. Violences physiques hors cadre familial
6. Trafic de stupéfiants

The implementation identifies them by their stable `crime_categories.code`, not their
display labels. The basket version is returned by the API so a later methodological
change cannot be mistaken for continuity with an older score.

## Comparable cohorts

Each city-year receives a six-bit availability mask. A bit is set only when that basket
category has a published, non-null rate.

A city is eligible for the comparative index only when:

- at least three basket categories are available;
- its comparison cohort contains at least 50 cities;
- its reference population is positive;
- every category used by the score has a non-null official rate.

A cohort is defined by:

- statistical year;
- population band;
- exact six-bit availability mask.

The population bands reuse the current application bands: under 1,000; 1,000-4,999;
5,000-9,999; 10,000-49,999; 50,000-99,999; and 100,000 or more.

This means every pair of cities ranked together has the same available indicators and a
similar population scale. Masked values are neither replaced nor estimated.

On the current 2025 data, 19,076 cities have at least three published basket rates. Of
those, 17 have no positive reference population, and 18,117 meet the minimum cohort size
of 50. A further 942 cities with a positive population fall into smaller exact cohorts.
Only 1,878 cities have all six basket rates, so requiring complete coverage would make
the feature unnecessarily narrow.

## Score calculation

For each published basket category:

1. Calculate its `percent_rank` from the official `rate_per_1000` among cities in the
   same year and population band where that category is published.
2. Average the category percentiles available in the city's fixed basket.
3. Rank that average inside the city's exact cohort, defined above.
4. Expose the final cohort percentile as an integer index from 0 to 100.

Lower values mean lower relative exposure and higher values mean higher relative
exposure. Equal weighting is used to avoid introducing unsupported policy weights.

The existing six color bands apply only to this final cohort percentile. They no longer
apply to the partial cross-category rate.

## Confidence and API contract

The comparative result contains:

```ts
type ComparativeIndex = {
  value: number | null;
  status: "comparable" | "insufficient-coverage" | "cohort-too-small" | "population-unavailable";
  confidence: "high" | "medium" | "low" | null;
  basketVersion: string;
  publishedBasketCategoryCount: number;
  basketCategoryCount: 6;
  basketAvailability: Array<{ code: string; label: string; available: boolean }>;
  cohortSize: number;
  populationBand: string | null;
};
```

Confidence depends only on basket coverage:

- six published categories: high;
- four or five: medium;
- three: low;
- fewer than three: no index.

The API also returns the basket category codes and availability status so the interface
can explain exactly what contributed to a score.

## Interface behavior

The main table separates these columns:

- published facts;
- partial published rate;
- overall publication coverage;
- comparative index and confidence.

Only the comparative index cell is colored. Its tooltip or accessible description names
the population band, basket coverage and cohort size. Unavailable indices display
`Non comparable`, never zero.

The city detail page uses the same separation. The current department, region and France
rates are labelled as partial published aggregates and do not receive comparative
colors. They should eventually be replaced by official SSMSI department and region
aggregates when those imports are implemented.

Nearby-city colors use the same stable comparative index as the main table. Filtering a
radius does not recalculate percentiles from only the visible nearby cities.

## Compatibility and annual updates

The basket and score are year-driven and require no frontend change when a new year is
imported. Expected category counts and cohort sizes are calculated for the selected
year. A version change to the basket must use a new `basketVersion`.

Existing `globalIncidentCount`, `globalRatePer1000` and
`globalRatePercentile` response fields are replaced internally by the explicit published
metric and comparative-index structures. This application has no external API consumers,
so a temporary compatibility alias is unnecessary.

## Verification

Automated tests must cover:

- all-masked statistics remain null;
- genuine published zeroes remain zero;
- exact availability masks create distinct cohorts;
- cities with fewer than three basket categories have no index;
- cohorts below 50 cities have no index;
- category percentile, composite average and final cohort rank calculations;
- population-band boundaries;
- search, detail and nearby endpoints return the same index for the same city-year;
- partial metrics never provide a color percentile;
- filters and sorting use the requested published metric or comparative index explicitly.

Read-only integration checks must compare API results with independent SQL calculations
for representative high-, medium-, low- and unavailable-confidence cities.
