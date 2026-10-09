import { NextResponse } from "next/server";
import { ZodError } from "zod";

import {
  NearbyOriginNotFoundError,
  parseNearbyCitySearchParams,
  searchNearbyCities
} from "@/server/nearby-city-search";
import { comparativeIndexMetadata } from "@/server/comparative-index";
import { pool } from "@/server/db";

type RouteContext = {
  params: Promise<{ inseeCode: string }>;
};

export async function GET(request: Request, context: RouteContext) {
  try {
    const { inseeCode } = await context.params;
    const url = new URL(request.url);
    const params = parseNearbyCitySearchParams(inseeCode, url.searchParams);
    const result = await searchNearbyCities(pool, params);

    return NextResponse.json({
      filters: params,
      methodology: comparativeIndexMetadata,
      ...result
    });
  } catch (error) {
    if (error instanceof NearbyOriginNotFoundError) {
      return NextResponse.json({ error: error.message }, { status: 404 });
    }

    if (error instanceof ZodError) {
      return NextResponse.json(
        {
          error: "Paramètres invalides",
          details: error.issues
        },
        { status: 400 }
      );
    }

    console.error(error);
    return NextResponse.json({ error: "Erreur interne du serveur" }, { status: 500 });
  }
}
