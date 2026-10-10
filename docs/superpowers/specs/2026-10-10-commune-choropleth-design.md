# Choroplèthe des communes

## Objectif

Remplacer les points statistiques de la carte nationale par des polygones communaux remplis selon l'indicateur choisi. L'utilisateur doit voir la surface de chaque commune colorée, tout en conservant la navigation nationale progressive et les filtres cartographiques existants.

## Décisions produit

- Les communes sont l'unité colorée : indice comparatif, catégorie SSMSI publiée, indice environnemental, prix d'achat ou loyer selon le sélecteur courant.
- Les couleurs, statuts d'indisponibilité et infobulles réutilisent les données et règles existantes. Une valeur absente reste indisponible/grise ; une valeur masquée SSMSI reste masquée.
- Le niveau national conserve des repères régionaux, puis départementaux, neutres et uniquement destinés à la navigation. Aucun indice, taux ou total n'est fabriqué pour ces territoires.
- À partir du niveau communal, seules les géométries qui intersectent le champ visible sont renvoyées et rendues. Le déplacement de la carte ne charge donc pas la France entière.
- Les frontières administratives sont des données géographiques distinctes des observations SSMSI et des métriques dérivées.
- Aucun fournisseur cartographique payant n'est ajouté. La [documentation officielle de geo.api.gouv.fr](https://geo.api.gouv.fr/decoupage-administratif/communes) expose les contours des communes en GeoJSON (`format=geojson`, `geometry=contour`).

## Architecture des données

- Ajouter une migration additive créant une colonne `geometry(MultiPolygon, 4326)` distincte du point `cities.geom`, avec index spatial GiST.
- Ajouter un import idempotent des contours par code INSEE depuis le référentiel public, avec métadonnées de source, millésime/édition et contrôle de couverture. L'import est découpé en lots géographiques raisonnables ; un lot vide ou anormalement partiel échoue sans déclarer l'import terminé.
- Ne pas écraser latitude/longitude ou le point-centroïde utilisés par les recherches par rayon, l'environnement et le cadrage existant.
- Stocker des géométries communales valides dans PostGIS ; réparer ou rejeter explicitement les géométries invalides plutôt que de les dessiner de façon imprévisible.

## API et rendu

- Étendre l'API de carte existante pour fournir, au niveau communal, les contours GeoJSON et les champs de métrique déjà nécessaires aux couleurs et infobulles.
- Filtrer les communes par intersection spatiale indexée avec l'emprise demandée, et non par position de leur centroïde : une commune dont le polygone traverse le bord de l'écran doit apparaître.
- Simplifier les géométries à la volée pour l'affichage selon le zoom, en préservant la topologie. Le calcul se fait dans un SRID métrique adapté avant le retour en WGS84 ; il ne modifie jamais les frontières stockées.
- Borner les réponses et éviter le chargement de détails géométriques hors champ. Si une emprise dépasse le budget de rendu, l'API retourne un état explicite « zoomez davantage » avec les limites demandées plutôt que de tronquer silencieusement la carte.
- Rendre les surfaces avec la couche GeoJSON/Leaflet en réutilisant exactement le style de couleur calculé actuellement pour chaque commune. Les événements de sélection ouvrent la fiche communale et conservent l'année.
- Conserver les points-centroïdes de la base pour la proximité, les distances et les calculs environnementaux ; la choroplèthe ne les remplace pas.
- Les changements rapides d'emprise ou de zoom gardent la protection existante contre les réponses réseau obsolètes.

## Hors périmètre

- Colorer les régions ou départements avec une statistique agrégée.
- Modifier les définitions SSMSI, le panier comparatif, les percentiles, les données de prix, les scores ou leurs provenances.
- Transformer les valeurs masquées ou absentes en valeurs numériques.
- Remplacer le fond OpenStreetMap ou les coordonnées communales existantes.

## Vérification attendue

- Migration neuve et mise à niveau : colonne polygonale, SRID, index GiST et absence de modification des coordonnées ponctuelles.
- Import : correspondance par code INSEE, relance sans doublon, validation des géométries et refus d'une réponse vide/partielle ; couverture des communes affichée ou diagnostiquée séparément des valeurs statistiques.
- API : inclusion d'une commune intersectant le viewport malgré un centroïde hors viewport, exclusion des géométries éloignées, métadonnées et snapshot cohérents, simplification valide et limites de taille explicites.
- Styles/UI : chaque indicateur reprend son code couleur/statut ; masqué, absent et sans géométrie restent distingués ; clic vers la bonne fiche ; les repères région/département restent neutres.
- Tests ciblés, suite complète, typecheck, build, puis contrôle visuel aux niveaux France, département et commune sur desktop et mobile, avec une commune côtière et un viewport urbain dense.
