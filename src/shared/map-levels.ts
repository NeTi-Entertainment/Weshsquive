export const NATIONAL_MAP_REGION_MAX_ZOOM = 5;
export const NATIONAL_MAP_DEPARTMENT_MAX_ZOOM = 7;

export type NationalMapLevel = "region" | "department" | "commune";

export function getNationalMapLevel(zoom: number): NationalMapLevel {
  if (zoom <= NATIONAL_MAP_REGION_MAX_ZOOM) return "region";
  if (zoom <= NATIONAL_MAP_DEPARTMENT_MAX_ZOOM) return "department";
  return "commune";
}
