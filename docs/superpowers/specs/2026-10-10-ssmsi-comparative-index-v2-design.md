# Indice comparatif SSMSI v2

## Objectif

Réduire fortement les communes sans couleur tout en respectant strictement la
diffusion SSMSI. L'indice reste un calcul relatif propre à l'application. Il ne
doit jamais devenir une somme de catégories, un total de faits, ni un taux global
rapporté à la population.

Les statistiques officielles restent inchangées dans `crime_stats`. Une valeur
`diff` est une statistique communale publiée. Une valeur `ndiff` reste masquée et
ses champs communaux `incident_count` et `rate_per_1000` restent nuls. Aucun zéro,
historique glissant ou autre valeur communale n'est déduit du masquage.

Cette conception remplace les règles de cohorte et de score de
`2026-10-09-comparative-index-design.md`. Le panier fixe de six catégories et le
principe d'une moyenne à poids égal sont conservés.

## Référentiel SSMSI

Le SSMSI définit `complement_info_nombre` et `complement_info_taux` comme les
moyennes, pour un indicateur et une année, des communes du même département dont
la valeur est sous secret statistique. Ces compléments ne sont pas des valeurs de
la commune.

L'application peut utiliser `complement_info_taux` comme fallback pour une
composante de l'indice uniquement. Elle ne doit jamais :

- l'afficher dans une cellule de statistique communale ;
- l'utiliser pour satisfaire un filtre sur un taux ou un nombre communal ;
- le restituer dans l'historique comme une observation communale ;
- le substituer à `rate_per_1000` ou `incident_count` dans les données brutes ;
- présenter le score résultant comme entièrement fondé sur des données publiées.

`complement_info_nombre` reste conservé pour la traçabilité officielle mais n'est
pas utilisé dans le score, lequel compare des taux homogènes par catégorie.

## Panier fixe

La version `residential-risk-v2` conserve six composantes :

1. Cambriolages de logement
2. Vols de véhicule
3. Vols dans les véhicules
4. Destructions et dégradations volontaires
5. Violences physiques hors cadre familial
6. Trafic de stupéfiants

Chaque composante a le même poids. Les catégories ne sont jamais additionnées,
car leurs unités de compte sont hétérogènes. Le cambriolage conserve son taux pour
1 000 logements ; les cinq autres composantes conservent leur taux SSMSI pour
1 000 habitants.

La migration v2 corrige les métadonnées dérivées de dénominateur déjà présentes
en base pour les catégories officielles documentées. Cette correction ne modifie
aucune valeur SSMSI. Une catégorie nouvelle ou non documentée garde la base
`unknown` et reste exclue de l'indice.

## Valeur effective d'une composante

Pour une commune, une année et une catégorie du panier :

1. Si `publication_status = 'published'` et que `rate_per_1000` est présent, la
   composante utilise ce taux communal officiel avec la provenance `published`.
2. Sinon, si `publication_status = 'masked'` et que `complement_info_taux` est
   présent, la composante utilise ce complément départemental avec la provenance
   `department-masked-average`.
3. Dans tous les autres cas, la composante est indisponible.

Le fallback n'est autorisé que pour une ligne explicitement `masked`. Une ligne
`unknown`, une ligne absente ou un complément isolé ne déclenche aucune
estimation. Un taux communal publié égal à zéro reste prioritaire et vaut zéro.

## Cohortes de référence

Les six tranches actuelles deviennent cinq tranches afin d'éviter une cohorte de
seulement 42 communes au-dessus de 100 000 habitants :

- moins de 1 000 habitants ;
- 1 000 à 4 999 ;
- 5 000 à 9 999 ;
- 10 000 à 49 999 ;
- 50 000 habitants ou plus.

Le masque exact de disponibilité ne définit plus une cohorte. Il reste disponible
comme information descriptive sur les composantes publiées.

Pour chaque année, tranche de population, catégorie, unité de compte et base de
taux, la distribution de référence contient uniquement les taux communaux
`published`. Les compléments estimatifs ne peuvent donc ni déplacer ni densifier
la distribution servant de référence.

Une composante n'est comparable que si sa distribution de référence contient au
moins 50 valeurs publiées. Dans les données 2025 actuelles, la fusion de la tranche
supérieure porte sa cohorte à 133 communes et toutes les autres combinaisons du
panier dépassent ce seuil.

## Percentile et indice final

Pour chaque valeur effective, publiée ou estimée, calculer sa position dans la
distribution publiée de sa catégorie et de sa tranche démographique. Le percentile
doit reproduire la sémantique de `percent_rank` : le nombre de valeurs publiées
strictement inférieures divisé par `taille_reference - 1`, borné entre 0 et 1.
Les ex aequo reçoivent donc le même percentile.

L'indice final est :

```text
100 * moyenne(percentile de chaque composante comparable)
```

Chaque composante a un poids égal. Il n'y a pas de second classement du score
moyen, pas de classement par masque de disponibilité, et aucune somme de nombres
ou de taux entre catégories. La valeur finale est arrondie à l'entier pour
l'affichage et reste comprise entre 0 et 100.

Un indice nécessite :

- une population strictement positive permettant de choisir la tranche ;
- au moins trois composantes effectives dont la cohorte publiée contient au moins
  50 communes.

Avec les données 2025 actuelles, les six composantes sont effectives pour toutes
les communes ayant une population exploitable. Le seuil de trois reste toutefois
une règle générale pour les futurs millésimes et les éventuelles lignes absentes.

## Provenance et statuts

L'indice expose séparément sa disponibilité et sa provenance :

```ts
type ComparativeIndexStatus =
  | "comparable"
  | "insufficient-coverage"
  | "reference-cohort-too-small"
  | "population-unavailable";

type ComparativeIndexProvenance =
  | "published-only"
  | "partially-estimated"
  | "estimated-only"
  | "unavailable";
```

Les règles de provenance sont :

- `published-only` : toutes les composantes retenues utilisent un taux communal
  publié ;
- `partially-estimated` : au moins une composante retenue est publiée et au moins
  une utilise un complément départemental ;
- `estimated-only` : toutes les composantes retenues utilisent des compléments
  départementaux ;
- `unavailable` : aucun indice n'est calculé.

L'API fournit aussi `publishedComponentCount`, `estimatedComponentCount`,
`comparableComponentCount`, `basketCategoryCount`, le masque des composantes
publiées, la tranche de population, la taille minimale des cohortes effectivement
utilisées et `basketVersion`.

Le champ historique `comparative_index_confidence` est remplacé dans le contrat
applicatif par la provenance et la complétude du panier. Une migration additive
peut conserver son nom physique pendant la transition, mais aucune interface ne
doit appeler cette valeur « confiance ».

## Stockage dérivé et rafraîchissement

La migration additive étend les vues de référence et les tables d'instantanés avec
les compléments nécessaires au calcul et les nouvelles métadonnées de provenance.
Les tables brutes restent la source de vérité et ne stockent aucun percentile ni
indice.

`refresh_search_metrics.sql` construit intégralement une nouvelle génération,
calcule les percentiles depuis les seules valeurs publiées, écrit les scores et
leur provenance, puis active la génération atomiquement selon le mécanisme
existant. L'ancienne génération reste servie en cas d'échec.

La mise à niveau locale applique la migration, corrige les dénominateurs dérivés,
reconstruit l'instantané et vérifie l'absence de différence sur les valeurs brutes
SSMSI.

## Contrats applicatifs

Recherche, proximité, fiche, comparaison et carte lisent le même indice depuis
l'instantané actif. Les filtres et tris sur l'indice acceptent les trois
provenances comparables ; le résultat expose toujours la provenance pour éviter
toute ambiguïté.

Les objets de catégorie continuent à restituer uniquement :

- la valeur communale lorsqu'elle est publiée ;
- le statut masqué lorsque la ligne est `ndiff` ;
- l'absence de donnée dans les autres cas.

Les compléments ne sont pas ajoutés aux statistiques communales des réponses API.
Ils n'apparaissent que sous forme de compteurs et de provenance dans l'objet de
l'indice.

## Interface

Les couleurs continuent de représenter la valeur 0-100 de l'indice. Leur rendu
indique en plus la provenance :

- publié uniquement : remplissage normal et contour plein ;
- partiellement estimé : même couleur avec opacité légèrement réduite et contour
  discontinu ;
- entièrement estimé : même couleur avec opacité plus faible et contour discontinu
  renforcé ;
- indisponible : gris.

La légende explique ces quatre états une seule fois par vue cartographique. Une
couleur estimée ne doit jamais être légendée comme une statistique communale
publiée.

Dans les tableaux, fiches, comparaisons et popups :

- afficher `Données communales publiées`, `Partiellement estimé`,
  `Entièrement estimé` ou `Indice indisponible` ;
- indiquer le nombre de composantes publiées et estimées ;
- expliquer dans le détail ou l'infobulle qu'un fallback est une moyenne SSMSI des
  communes masquées du département ;
- conserver `Non publié` sur toute statistique communale `ndiff`.

## Indice environnemental

L'indice environnemental peut consommer les indices v2 comparables, y compris
ceux comportant des fallbacks, mais il doit propager leur provenance :

- `published-only` si toutes les communes effectivement pondérées ont un indice
  `published-only` ;
- `partially-estimated` si au moins une commune pondérée utilise un fallback ;
- `unavailable` lorsque les règles existantes de couverture ne permettent aucun
  score.

La réponse fournit les nombres de voisines à indice publié, partiellement estimé et
entièrement estimé. L'interface affiche une annotation unique précisant que
l'indice environnemental peut inclure des scores estimatifs départementaux.

## Compatibilité annuelle

Une nouvelle année SSMSI déclenche le même calcul sans modification du frontend.
Le contrôle de rafraîchissement échoue avant activation si une catégorie du panier
n'a pas de base de taux documentée, si les compléments sont incohérents au sein
d'un groupe département-année-catégorie, ou si aucune distribution publiée ne
permet de calculer les composantes attendues.

Une évolution ultérieure du panier, des tranches ou de la formule doit utiliser une
nouvelle `basketVersion`. Les scores v1 et v2 ne sont pas présentés comme une même
série méthodologique.

## Vérifications

Les tests automatisés couvrent au minimum :

- priorité d'un taux `diff`, y compris un vrai zéro publié ;
- `ndiff` conservé avec valeurs communales nulles ;
- complément utilisé seulement comme composante estimative ;
- ligne `unknown` ou absente jamais estimée ;
- distribution de référence constituée uniquement de valeurs publiées ;
- percentile calculé séparément pour chaque catégorie, année, tranche, unité et
  base de taux ;
- ex aequo et bornes du percentile ;
- moyenne à poids égal, sans somme intercatégories ni second reclassement ;
- suppression du masque exact comme critère de cohorte ;
- fusion de la tranche supérieure et seuil de 50 références ;
- les quatre provenances et les quatre statuts de disponibilité ;
- cohérence du même indice entre recherche, proximité, fiche, comparaison et
  carte ;
- propagation de provenance dans l'indice environnemental ;
- légendes et styles distincts sur les interfaces ;
- reconstruction atomique et conservation de l'ancien instantané en cas d'échec ;
- aucune modification des valeurs brutes avant et après migration.

Un contrôle d'intégration sur la base 2025 compare les résultats à un calcul SQL
indépendant. Les résultats attendus après prise en compte de la population sont
environ 1 875 indices `published-only`, 31 778 `partially-estimated`, 1 199
`estimated-only` et 23 `population-unavailable`. Ces nombres servent de garde-fou
pour le jeu local actuel, pas de constantes applicatives.

La validation finale comprend les tests ciblés, la suite complète, le typecheck,
le build, le rafraîchissement réel de l'instantané local et un contrôle visuel des
parcours carte, recherche, proximité, fiche et comparaison sur ordinateur et
mobile.

Aucun commit n'est créé.
