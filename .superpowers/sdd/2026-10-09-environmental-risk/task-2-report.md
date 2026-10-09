# Task 2: Présentation du résumé environnemental

## Résultat

La fiche communale affiche maintenant une section serveur « Environnement statistique » qui consomme directement `CityDetail.environmentalRisk`. Elle présente les rayons de 25, 50, 100 et 200 km avec l’indice sur 100, son statut, le nombre de voisines avec indice sur le nombre total de voisines, et la couverture pondérée.

Les scores sont formatés en français avec une décimale et les couvertures en pourcentage sans décimale. Les quatre statuts utilisent les libellés approuvés. Une valeur nulle apparaît comme « Non disponible », sans zéro de remplacement et sans classe de couleur `stat-band-*`. Les scores présents réutilisent les bandes de couleur de l’indice comparatif existant.

Une annotation méthodologique unique décrit la moyenne pondérée par distance et précise qu’il ne s’agit ni d’une statistique SSMSI, ni d’un percentile environnemental, ni d’une probabilité individuelle ou d’une garantie de sécurité. Aucun calcul serveur, score ou donnée officielle n’a été modifié.

## Fichiers

- Créé `app/environmental-risk-section.tsx` : tableau accessible des rayons, scores, statuts et couvertures.
- Créé `src/client/environmental-risk-ui.ts` : formatteurs de score, statut et couverture.
- Modifié `app/communes/[inseeCode]/page.tsx` : insertion de la section dans la fiche communale.
- Modifié `app/globals.css` : styles de tableau, couleur et adaptation responsive.
- Créé `tests/environmental-risk-ui.test.ts` : tests de formatage et rendu serveur.

## Vérifications

- TDD : les tests ont d’abord échoué car les helpers UI puis le composant n’existaient pas; ils passent après implémentation.
- `npm test -- --reporter=verbose tests/environmental-risk-ui.test.ts` : 4 tests réussis.
- `npm test -- --reporter=verbose` : 65 tests réussis, 1 test ignoré (`search-query-explain.test.ts`).
- `npm run typecheck` : réussi.
- `npm run build` : réussi; la route dynamique `/communes/[inseeCode]` est compilée.

Le test PostGIS/plan de requête ignoré n’a pas été exécuté. Il n’était pas nécessaire pour cette modification de présentation, qui n’altère aucune requête ni aucun calcul. Aucun commit, dépôt Git, branche ou worktree n’a été créé.
