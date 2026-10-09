export type PropertyMarketMetricKind = "sale" | "rent";
export type SalePropertyType = "all" | "apartment" | "house";
export type RentPropertyType = "apartment" | "house";
export type PropertyMarketPropertyType = SalePropertyType | RentPropertyType;

export type PropertyMarketStoredStatus =
  | "published"
  | "source-uncovered"
  | "no-data"
  | "insufficient-sample"
  | "non-communal-estimate"
  | "insufficient-quality"
  | "invalid-value";

export type PropertyMarketDisplayStatus =
  | PropertyMarketStoredStatus
  | "year-unavailable";

export type PropertyMarketSelection =
  | { kind: "sale"; propertyType: SalePropertyType }
  | { kind: "rent"; propertyType: RentPropertyType };

export type PropertyMarketMetric = PropertyMarketSelection & {
  valuePerM2: string | null;
  lowerBoundPerM2: string | null;
  upperBoundPerM2: string | null;
  sampleCount: number | null;
  nationalPercentile: string | null;
  status: PropertyMarketDisplayStatus;
  sourceSystem: string | null;
  sourceYear: number | null;
};
