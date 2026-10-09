import type { Metadata } from "next";
import type { ReactNode } from "react";

import "leaflet/dist/leaflet.css";
import "./globals.css";

export const metadata: Metadata = {
  title: "App Criminalite",
  description: "Recherche communale des statistiques officielles SSMSI."
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="fr">
      <body>{children}</body>
    </html>
  );
}
