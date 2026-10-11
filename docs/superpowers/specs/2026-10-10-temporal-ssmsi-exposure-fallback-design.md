# Repli temporel de l'indice d'exposition SSMSI

## Objectif

Pour une année sélectionnée, privilégier les taux communaux SSMSI publiés de la
même commune avant d'utiliser le complément départemental de l'année sélectionnée.
Le calcul reste une moyenne à poids égal de six composantes normalisées selon les
ancres fixes 2025. Aucune statistique brute ne sera
fabriquée ou remplacée par une valeur dérivée.

L'indice est indisponible lorsque moins de trois composantes sur six sont
exploitables. Aucune moyenne pluriannuelle n'est calculée.

## Sources et périmètre audités

Le CSV communal officiel consolidé actuellement publié par le SSMSI est produit
avec la géographie 2026 et contient les observations annuelles 2016 à 2025. Son
en-tête est `CODGEO_2026`; chaque année du fichier auditée contient 523 800 lignes
et les 15 indicateurs. La base locale avant changement ne contient que 2025, soit
523 125 observations pour 34 875 communes et 15 catégories.

Le schéma brut `crime_stats` conserve déjà le statut, le taux communal publié, les
unités et dénominateurs, les compléments, le code INSEE, l'année et la source.
L'importateur actuel peut filtrer un millésime et fait un upsert par commune,
année, catégorie et source, mais son nom de colonne temporaire est codé en dur
sur `codgeo_2026`. Le code géographique sera rendu générique sans correspondance
administrative déduite : une ligne historique ne sera rattachée qu'à une commune
ayant exactement le même code INSEE.

Le backfill importera les millésimes 2016 à 2024 à partir de la ressource
consolidée officielle. Les lignes 2025 existantes ne seront ni supprimées ni
réécrites. L'import sera relançable sans doublon et produira des lots distincts
par année. Les nouvelles années continueront à être importées par le pipeline
annuel normal.

## Sélection d'une composante

Pour une commune `C`, une année cible `N` et une catégorie du panier, chercher
dans cet ordre :

1. La ligne de `C` en `N`, si elle est publiée (`diff`) et possède un taux valide.
2. La première ligne publiée avec taux valide dans l'ordre `N-1`, `N-2`, `N-3`.
3. Le `complement_info_taux` de `C`, pour la ligne explicitement masquée (`ndiff`)
   de l'année `N`.
4. Aucune composante.

Chaque candidat publié doit avoir la même unité de compte et le même dénominateur
que l'ancre de sa catégorie. Les taux nuls publiés sont valides et prioritaires.
Les lignes inconnues, les lignes masquées historiques, les années antérieures à
`N-3`, les compléments historiques et les valeurs d'un autre code INSEE sont
ignorés. Un complément n'est admissible que pour la ligne `ndiff` de l'année
cible et n'est jamais une donnée communale.

Le score de composante reste `min(100, taux / ancre_2025 * 100)` ; le score global
est la moyenne à poids égal des composantes exploitables, sans reclassement. La
version de panier devient `absolute-exposure-v2`, car la provenance temporelle
change le sens de la série même si la formule numérique et les ancres sont
conservées.
Pour les millésimes antérieurs au début officiel de la série, la recherche
historique ne peut naturellement utiliser que les années disponibles depuis
2016.

## Garde-fou et couverture

Le plafond actuel `X = 10` conserve sa sémantique : seuls les nombres SSMSI
réellement publiés de l'année cible, avec les unités homogènes actuellement
retenues par le garde-fou, peuvent le déclencher. Ni les nombres historiques, ni
les taux, ni les compléments départementaux n'y contribuent.

Un score est produit à partir de trois composantes utilisables ou plus. Les
métadonnées globales contiennent le nombre de composantes publiées en `N`, le
nombre publiées en historique, le nombre estimées par complément départemental,
la couverture sur six et l'année source la plus ancienne effectivement utilisée.

Chaque composante conserve dans les métriques dérivées :

- `sourceYear` : année du taux utilisé, nulle si indisponible ;
- `provenance` : `current-published`, `historical-published`,
  `department-masked-average` ou `unavailable` ;
- le taux effectif, qui reste distinct de la valeur brute de l'année cible ;
- le score normalisé ou `null`.

## Provenance de l'indice et interface

La provenance globale distingue :

- données communales de l'année cible, quand les composantes utilisées sont
  toutes publiées en `N` ;
- données communales complétées par l'historique, s'il existe au moins une
  composante historique et aucune estimation départementale ;
- partiellement estimé, si des compléments départementaux coexistent avec des
  données communales actuelles ou historiques ;
- entièrement estimé, si toutes les composantes utilisées sont des compléments ;
- indisponible, si moins de trois composantes sont exploitables.

Le détail de la fiche et les objets de catégorie de l'API exposent l'année et la
provenance de la composante. Les nombres, taux et statuts bruts de l'année cible
restent inchangés et affichent toujours `Non publié` pour `ndiff`. La carte et les
résumés exposent le nombre de composantes par provenance, la couverture et
l'année la plus ancienne, sans devoir lister chaque source dans leur popup.

Le calque par catégorie continue à utiliser les valeurs publiées du millésime
cible ; le fallback historique ne s'applique qu'à l'indice global. L'indice
environnemental conserve sa formule spatiale actuelle. Il propagera l'état de ses
communes contributrices, le nombre de scores courants, historiques et estimés,
ainsi que l'année source la plus ancienne effectivement prise en compte.

## Instantanés et compatibilité

Une migration additive étend uniquement les métriques dérivées et les tables de
snapshot pour stocker les métadonnées de provenance par composante et par indice.
Les vues restent la référence de calcul. La reconstruction écrit un nouvel
instantané puis le bascule atomiquement ; l'ancien instantané reste actif en cas
d'échec.

La version `absolute-exposure-v2` et ses métadonnées indiquent la fenêtre maximale
de trois années antérieures et le seuil minimal de trois composantes. L'instantané
environnemental continue à agréger les indices communaux disponibles ; il
propage leurs états et la couverture sans réinterpréter une estimation comme une
donnée communale.

## Vérifications

Les tests couvrent les priorités `N` puis `N-1` à `N-3`, les quatre états de
provenance par composante, les zéros publiés, l'exclusion des lignes `ndiff` et
`unknown`, la priorité historique sur le complément, le refus de `N-4`, les
unités/dénominateurs non concordants, le seuil de trois composantes et le
garde-fou limité aux nombres publiés de l'année cible.

Les tests d'import couvrent les géographies `CODGEO_20xx`, l'association par code
INSEE exact, le backfill 2016–2024 idempotent, les lots annuels, l'absence de
modification des lignes 2025 et le refus d'un millésime absent. Les tests de
snapshot/API/UI couvrent les métadonnées et libellés dans la recherche, la fiche,
les comparaisons, le rayon et la carte.

La validation sur la base locale compare le snapshot avant/après pour Nivillers,
Porta, Norrois, Villegongis et Beauvais, vérifie chaque catégorie, son année,
sa provenance et son taux, puis exécute la suite ciblée, la suite complète, le
typecheck, le build et les parcours locaux. Aucun commit ne sera créé.
