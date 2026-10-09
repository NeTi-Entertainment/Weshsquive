import { NextResponse } from "next/server";
import { ZodError } from "zod";

import { parseNationalMapParams, searchNationalMap } from "@/server/national-map";
import { pool } from "@/server/db";

export async function GET(request: Request) {
  try {
    const url = new URL(request.url);
    const params = parseNationalMapParams(url.searchParams);
    const result = await searchNationalMap(pool, params);
    return NextResponse.json({ filters: params, ...result });
  } catch (error) {
    if (error instanceof ZodError) {
      return NextResponse.json(
        { error: "Paramètres cartographiques invalides", details: error.issues },
        { status: 400 }
      );
    }

    console.error(error);
    return NextResponse.json({ error: "Erreur interne du serveur" }, { status: 500 });
  }
}
