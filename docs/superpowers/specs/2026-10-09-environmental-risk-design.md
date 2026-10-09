# Indicateur de risque environnemental

## Objectif

Compléter l'indice comparatif propre à une commune par un indicateur distinct du contexte statistique autour d'elle. L'indice doit répondre à la question « quel est le niveau relatif des communes proches ? » sans modifier ni agréger les chiffres officiels SSMSI.

## Principes

- Les statistiques officielles restent inchangées. L'indice environnemental est une valeur dérivée et identifiée comme telle.
- L'indice comparatif existant est la seule entrée de l'indice environnemental. Un indice manquant n'est jamais remplacé par zéro.
- La commune d'origine est exclue de son propre environnement.
- Les distances sont calculées à vol d'oiseau entre les points géographiques des communes.
- Les rayons proposés sont 25, 50, 100 et 200 km, comme dans la recherche de proximité.
- L'indice décrit une exposition statistique relative, pas une probabilité individuelle, un niveau de criminalité officiel ou une garantie de sécurité.

## Calcul

Pour une commune cible, une année et un rayon `r`, retenir les autres communes géolocalisées à une distance `d` strictement inférieure à `r`. Chaque commune reçoit un poids linéaire selon sa distance :

```text
poids = 1 - d / r
```

L'indice environnemental est la moyenne pondérée des indices comparatifs disponibles :

```text
somme(indice comparatif * poids) / somme(poids des communes avec indice)
```

La couverture pondérée est la somme des poids des communes avec indice, divisée par la somme des poids de toutes les communes géolocalisées dans le rayon. Le décompte de couverture accompagne toujours le score : nombre de communes avec indice sur nombre total de voisines géolocalisées.

Le score n'est exploitable que si au moins trois voisines ont un indice et si la couverture pondérée atteint 50 %. Sinon, l'API renvoie une valeur nulle avec le statut « couverture insuffisante ». Les autres statuts distinguent notamment une origine sans coordonnées et l'absence de voisine dans le rayon. Un score valide est arrondi à une décimale et reste sur l'échelle 0-100 de l'indice comparatif.

Les indices comparatifs sont issus des cohortes statistiques déjà définies par l'application (année, tranche de population et disponibilité du panier). L'interface explique que l'environnement est une moyenne d'indices relatifs disponibles et affiche leur couverture, sans le présenter comme un agrégat officiel.

Cette moyenne n'est pas un percentile environnemental recalculé à l'échelle nationale. Elle ne doit pas être présentée comme un percentile du voisinage ni comme une mesure directement équivalente à l'indice propre de la commune.

## Calcul et cohérence des données

- Calculer les quatre rayons côté serveur à la demande, en s'appuyant sur l'index spatial PostGIS existant.
- Ajouter ces résultats à la réponse de la fiche commune. Utiliser le même `snapshot_id` que l'indice comparatif et les autres informations de cette fiche afin d'éviter de mélanger deux instantanés lors d'un rafraîchissement.
- Ne pas créer de migration ni de stockage persistant pour cette première version.
- Pour l'affichage cartographique, calculer les valeurs des communes représentées en lot et pour le rayon choisi; ne pas lancer une requête indépendante par marqueur. Mesurer les parcours et réévaluer un cache ou un calcul à la demande limité à la zone visible si le coût est trop élevé.

## Interface

### Fiche commune

Ajouter une section « Environnement statistique » présentant les quatre rayons. Chaque rayon affiche le score environnemental coloré selon les bandes existantes, le nombre de voisines exploitables, le nombre total de voisines géolocalisées et la couverture pondérée. En cas de données insuffisantes, afficher « Non disponible » avec une explication de couverture, jamais un zéro.

Une annotation méthodologique unique précise que le score est calculé par l'application à partir des indices comparatifs des voisines, pondérés selon leur distance, et qu'il ne s'agit pas d'une statistique officielle.

### Carte

Ajouter des critères de couleur « Environnement 25 km », « Environnement 50 km », « Environnement 100 km » et « Environnement 200 km ». Chaque marqueur est coloré selon le score environnemental de sa propre commune pour l'année sélectionnée et le rayon choisi. La fiche contextuelle du marqueur montre le score, le nombre de voisines exploitables et la couverture; une valeur insuffisante reste grise. Le score réutilise l'échelle visuelle existante, sans le qualifier de percentile environnemental.

La carte actuelle est une carte de points communaux : cette première version ne colore pas les polygones communaux et ne produit pas de surface continue.

## Vérifications

- Tests unitaires du poids à différentes distances, de l'exclusion de la commune cible, de l'agrégation pondérée et des seuils de couverture.
- Tests des statuts : origine sans coordonnées, aucun voisin, moins de trois indices disponibles, couverture pondérée sous 50 %, score disponible et indice manquant jamais traité comme zéro.
- Tests SQL garantissant l'utilisation du rayon, de l'année et du snapshot demandés, ainsi que de l'index spatial.
- Tests de contrat de la réponse fiche et de la carte; la carte doit réutiliser les valeurs en lot et rester grise pour les points non comparables.
- Exécuter typecheck, tests et build; contrôler les performances locales des vues fiche et carte.
- Aucun commit.
