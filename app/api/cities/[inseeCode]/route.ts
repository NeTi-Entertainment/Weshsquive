import { NextResponse } from "next/server";
import { ZodError } from "zod";

import { getCityDetail, parseCityDetailParams } from "@/server/city-detail";
import { comparativeIndexMetadata } from "@/server/comparative-index";
import { pool } from "@/server/db";

type RouteContext = {
  params: Promise<{ inseeCode: string }>;
};

export async function GET(request: Request, context: RouteContext) {
  try {
    const { inseeCode } = await context.params;
    const url = new URL(request.url);
    const params = parseCityDetailParams(inseeCode, url.searchParams);
    const city = await getCityDetail(pool, params);

    if (!city) {
      return NextResponse.json({ error: "Commune introuvable" }, { status: 404 });
    }

    return NextResponse.json({
      methodology: comparativeIndexMetadata,
      ...city
    });
  } catch (error) {
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
