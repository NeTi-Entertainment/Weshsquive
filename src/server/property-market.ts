import type {
  PropertyMarketMetric,
  PropertyMarketSelection,
  PropertyMarketStoredStatus
} from "@/shared/property-market";

export type PropertyMarketSelectionSqlParams = {
  yearPlaceholder: string;
  kindPlaceholder: string;
  propertyTypePlaceholder: string;
};

export type RawPropertyMarketColumns = {
  property_market_year_available: boolean;
  property_market_year: number | null;
  property_market_kind: "sale" | "rent" | null;
  property_market_property_type: "all" | "apartment" | "house" | null;
  property_market_value_per_m2: string | null;
  property_market_lower_bound_per_m2: string | null;
  property_market_upper_bound_per_m2: string | null;
  property_market_sample_count: number | null;
  property_market_national_percentile: string | null;
  property_market_display_status: PropertyMarketStoredStatus | null;
  property_market_source_system: string | null;
};

export const PROPERTY_MARKET_SELECT_COLUMNS = `
  coalesce(property_market_availability.year_available, false) as property_market_year_available,
  property_market.year as property_market_year,
  property_market.metric_kind as property_market_kind,
  property_market.property_type as property_market_property_type,
  property_market.value_per_m2 as property_market_value_per_m2,
  property_market.lower_bound_per_m2 as property_market_lower_bound_per_m2,
  property_market.upper_bound_per_m2 as property_market_upper_bound_per_m2,
  property_market.sample_count as property_market_sample_count,
  property_market.national_percentile as property_market_national_percentile,
  property_market.display_status as property_market_display_status,
  property_market.source_system as property_market_source_system
`.trim();

export function buildPropertyMarketSelection({
  yearPlaceholder,
  kindPlaceholder,
  propertyTypePlaceholder
}: PropertyMarketSelectionSqlParams): string {
  return `
left join property_market_metrics property_market
  on property_market.city_insee_code = c.insee_code
 and property_market.year = ${yearPlaceholder}
 and property_market.metric_kind = ${kindPlaceholder}
 and property_market.property_type = ${propertyTypePlaceholder}
left join lateral (
  select exists (
    select 1
    from property_market_metrics availability
    where availability.year = ${yearPlaceholder}
      and availability.metric_kind = ${kindPlaceholder}
      and availability.property_type = ${propertyTypePlaceholder}
  ) as year_available
) property_market_availability on true
`.trim();
}

export function mapPropertyMarketMetric(
  row: RawPropertyMarketColumns,
  selection: PropertyMarketSelection
): PropertyMarketMetric {
  if (row.property_market_year === null || row.property_market_display_status === null) {
    return {
      ...selection,
      valuePerM2: null,
      lowerBoundPerM2: null,
      upperBoundPerM2: null,
      sampleCount: null,
      nationalPercentile: null,
      status: row.property_market_year_available ? "no-data" : "year-unavailable",
      sourceSystem: null,
      sourceYear: null
    };
  }

  return {
    ...selection,
    valuePerM2: row.property_market_value_per_m2,
    lowerBoundPerM2: row.property_market_lower_bound_per_m2,
    upperBoundPerM2: row.property_market_upper_bound_per_m2,
    sampleCount: row.property_market_sample_count,
    nationalPercentile: row.property_market_national_percentile,
    status: row.property_market_display_status,
    sourceSystem: row.property_market_source_system,
    sourceYear: row.property_market_year
  };
}
