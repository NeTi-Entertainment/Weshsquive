import { NextResponse } from "next/server";
import { ZodError } from "zod";

import { parseCitySearchParams, searchCities } from "@/server/city-search";
import { comparativeIndexMetadata } from "@/server/comparative-index";
import { pool } from "@/server/db";

export async function GET(request: Request) {
  try {
    const url = new URL(request.url);
    const params = parseCitySearchParams(url.searchParams);
    const results = await searchCities(pool, params);

    return NextResponse.json({
      filters: params,
      methodology: comparativeIndexMetadata,
      count: results.length,
      results
    });
  } catch (error) {
    if (error instanceof ZodError) {
      return NextResponse.json(
        {
          error: "Invalid search parameters",
          details: error.issues
        },
        { status: 400 }
      );
    }

    console.error(error);
    return NextResponse.json({ error: "Internal server error" }, { status: 500 });
  }
}
