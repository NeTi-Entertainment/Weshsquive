import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("@/server/db", () => ({ pool: { query: vi.fn() } }));

import { GET } from "../app/api/cities/map/route";
import { pool } from "@/server/db";

describe("GET /api/cities/map", () => {
  beforeEach(() => vi.mocked(pool.query).mockReset());

  it("returns 400 for invalid bounds without querying the database", async () => {
    const response = await GET(new Request(
      "http://localhost/api/cities/map?year=2025&zoom=8&west=10&south=41&east=-5&north=52&criterion=comparativeIndex"
    ));

    expect(response.status).toBe(400);
    expect(pool.query).not.toHaveBeenCalled();
  });

  it("returns 400 when a rental layer requests the all-home type", async () => {
    const response = await GET(new Request(
      "http://localhost/api/cities/map?year=2025&zoom=8&west=-5&south=41&east=10&north=52&criterion=rentPrice&marketPropertyType=all"
    ));

    expect(response.status).toBe(400);
    expect(pool.query).not.toHaveBeenCalled();
  });

  it("returns a navigation-only regional payload", async () => {
    vi.mocked(pool.query).mockResolvedValue({
      rows: [{
        snapshot_id: "17",
        code: "75",
        name: "Nouvelle-Aquitaine",
        parent_code: null,
        parent_name: null,
        latitude: "45.5",
        longitude: "0.2",
        commune_count: 1200,
        west: "-1.8",
        south: "42.7",
        east: "2.6",
        north: "46.9"
      }],
      rowCount: 1
    } as never);

    const response = await GET(new Request(
      "http://localhost/api/cities/map?year=2025&zoom=5&west=-5&south=41&east=10&north=52&criterion=comparativeIndex"
    ));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toMatchObject({
      level: "region",
      snapshotId: "17",
      groups: [{ type: "region", code: "75", communeCount: 1200 }],
      communes: []
    });
    expect(body.groups[0]).not.toHaveProperty("comparativeIndex");
  });

  it("returns a commune polygon collection without legacy point markers", async () => {
    vi.mocked(pool.query).mockResolvedValue({ rows: [], rowCount: 0 } as never);

    const response = await GET(new Request(
      "http://localhost/api/cities/map?year=2025&zoom=8&west=-5&south=41&east=10&north=52&criterion=comparativeIndex"
    ));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toMatchObject({ level: "commune", snapshotId: null, communes: [], requiresZoom: false });
    expect(body).not.toHaveProperty("points");
  });
});
