# Calques immobiliers d'achat et de location

## Objectif

Ajouter à la carte de France des calques immobiliers communaux permettant de rapprocher visuellement, sans les fusionner, les indicateurs de sécurité et le marché immobilier pour une année donnée.

Les calques proposés sont :

- prix d'achat médian au mètre carré, tous logements résidentiels éligibles ;
- prix d'achat médian au mètre carré des appartements ;
- prix d'achat médian au mètre carré des maisons ;
- loyer d'annonce estimé au mètre carré et par mois des appartements ;
- loyer d'annonce estimé au mètre carré et par mois des maisons.

Les données immobilières ne participent à aucun indice de criminalité ou de risque environnemental. L'application ne calcule pas de score hybride sécurité/prix.

## Sources et vocabulaire

### Prix d'achat

La source est la base officielle [Demandes de valeurs foncières (DVF)](https://www.data.gouv.fr/datasets/demandes-de-valeurs-foncieres), dans sa diffusion normalisée et géolocalisée par data.gouv.fr. Les valeurs affichées sont des médianes calculées par l'application à partir des mutations éligibles ; elles ne doivent donc jamais être présentées comme un prix officiel publié directement pour la commune.

L'interface emploie la formulation « Prix d'achat médian » et l'unité `€/m²`.

La couverture DVF ne comprend pas l'Alsace, la Moselle et Mayotte. Les communes concernées restent grises avec une mention explicite d'absence de couverture DVF.

### Loyers

La source est la [Carte des loyers](https://www.data.gouv.fr/datasets/carte-des-loyers-indicateurs-de-loyers-dannonce-par-commune-en-2025), produite par l'ANIL et le ministère chargé du logement. Elle fournit des estimations de loyers d'annonce, charges comprises, pour des logements non meublés. Il ne s'agit ni de loyers effectivement signés ni d'une moyenne brute des annonces.

L'interface emploie la formulation « Loyer d'annonce estimé » et l'unité `€/m²/mois`.

Mayotte n'est pas couverte par cette source. Les communes non couvertes restent grises.

### Traçabilité

Chaque import conserve au minimum la source, l'URL ou l'identifiant de ressource, le millésime, la date de publication ou de révision connue, l'empreinte du fichier et la date d'import. Une révision officielle est distinguée d'un nouveau millésime.

## Modèle de données

Une migration additive crée des tables dédiées, sans modifier les observations SSMSI ni les instantanés de sécurité.

### Observations DVF conservées

Une table `property_sale_observations` conserve, pour chaque mutation résidentielle retenue :

- l'identifiant officiel de mutation ;
- le code INSEE de la commune ;
- la date et l'année de mutation ;
- la nature de mutation ;
- le type de local, limité à `apartment` ou `house` ;
- la valeur foncière officielle ;
- la surface réelle bâtie officielle ;
- le lot d'import et la source.

Les valeurs officielles sont conservées telles qu'elles sont diffusées. Le prix au mètre carré n'est pas écrit dans cette table : il reste une valeur dérivée.

L'import ne cherche pas à constituer une copie exhaustive de DVF. Il sélectionne les mutations résidentielles nécessaires au calcul communal selon la méthode documentée ci-dessous, tout en conservant sans altération les champs officiels utilisés.

### Observations de loyers conservées

Une table `property_rent_observations` conserve, pour chaque commune, année et type de logement disponible dans la source :

- le code INSEE ;
- l'année ;
- le type de logement, `apartment` ou `house` ;
- le loyer estimé au mètre carré ;
- les bornes basse et haute de l'intervalle publié ;
- le type de prédiction ;
- le nombre d'observations communal et celui de la maille, lorsqu'ils sont fournis ;
- le coefficient `R²` ajusté ;
- le lot d'import et la source.

Ces champs officiels sont conservés même lorsqu'ils ne satisfont pas les critères d'affichage. Leur exclusion éventuelle est une décision dérivée et explicable.

### Métriques dérivées

Une table ou un instantané `property_market_metrics` contient les métriques prêtes à servir à la carte, avec une clé unique comprenant :

- la commune ;
- l'année ;
- la nature de métrique, `sale` ou `rent` ;
- le type de logement, `all`, `apartment` ou `house` selon la métrique.

Elle contient notamment la valeur affichable, le nombre d'observations, le percentile national, le statut d'affichage et son motif. Les percentiles et statuts sont des calculs de l'application, jamais des données officielles.

Les index couvrent au minimum `(year, metric_kind, property_type, city_insee_code)` et les accès par commune et année. Le rafraîchissement immobilier est indépendant des instantanés statistiques SSMSI.

## Méthode des prix d'achat

Le calcul suit les principes publiés pour les statistiques DVF :

1. Les lignes sont regroupées par identifiant de mutation afin de ne pas compter plusieurs fois une même vente.
2. Les natures `Vente`, `Vente en l'état futur d'achèvement` et `Adjudication` sont éligibles.
3. Une mutation n'est retenue que si elle porte sur un unique bien résidentiel principal, appartement ou maison. Les dépendances ne sont pas comptées comme un second logement, mais une mutation comprenant plusieurs logements principaux est exclue.
4. La mutation doit pouvoir être rattachée sans ambiguïté à une seule commune.
5. La valeur foncière et la surface réelle bâtie doivent être présentes, finies et strictement positives.
6. Le prix dérivé est `valeur foncière / surface réelle bâtie`.
7. Les valeurs dérivées supérieures à `100 000 €/m²` sont exclues du calcul, conformément au garde-fou de la publication Statistiques DVF.
8. La valeur communale est la médiane des prix dérivés éligibles, calculée séparément par année et type de logement.

Le calque « tous logements » calcule la médiane de l'ensemble des mutations éligibles de maisons et d'appartements. Il ne fait pas la moyenne des deux médianes.

Une valeur n'est publiée et colorée qu'à partir de cinq mutations éligibles pour la commune, l'année et le type sélectionné. Sous ce seuil, la commune reste grise et le motif « Échantillon insuffisant » est renvoyé. Une absence de mutation n'est jamais assimilée à un prix nul.

Le percentile est calculé uniquement parmi les communes publiables de la même année et du même type de logement.

## Méthode des loyers

L'application ne recalcule pas le loyer estimé par l'ANIL. Elle importe la valeur et ses informations de qualité, puis applique une règle stricte d'éligibilité à l'affichage.

Une estimation est publiée et colorée uniquement si toutes les conditions suivantes sont satisfaites :

- le type de prédiction indique une estimation directe au niveau communal ;
- le nombre d'observations communal est supérieur ou égal à 30 ;
- le `R²` ajusté est supérieur ou égal à `0,5` ;
- l'estimation et les bornes de l'intervalle sont présentes, finies, cohérentes et strictement positives.

Une estimation issue d'une maille plus large, une qualité insuffisante ou une valeur absente reste grise. Le motif précis est renvoyé : « Estimation non communale », « Qualité insuffisante », « Donnée absente » ou « Année indisponible ».

Le percentile est calculé uniquement parmi les communes affichables de la même année et du même type de logement. Aucune interpolation et aucun remplacement par zéro ne sont autorisés.

## API cartographique

L'API de la carte nationale accepte deux nouveaux critères :

- `salePrice`, avec `all`, `apartment` ou `house` ;
- `rentPrice`, avec `apartment` ou `house`.

L'année sélectionnée dans l'application s'applique au calque immobilier. Une année sans donnée pour la métrique choisie produit des communes grises et un état explicite, sans revenir silencieusement à un autre millésime.

Pour une commune, la réponse fournit au minimum :

- la valeur affichable ou `null` ;
- l'unité ;
- le percentile ou `null` ;
- le nombre d'observations ou de mutations ;
- le statut d'affichage et son motif ;
- les bornes de l'intervalle pour les loyers ;
- le nom de la source et son millésime.

L'API conserve le chargement spatial existant : au niveau communal, seules les communes dans l'emprise visible sont demandées. Les requêtes ne doivent pas déclencher une lecture par commune ni charger toute la France à chaque déplacement de carte.

Aux niveaux région et département, les marqueurs agrégés restent neutres et servent uniquement à naviguer. Les calques immobiliers deviennent colorés lorsque le niveau de zoom affiche les communes ; aucune moyenne régionale ou départementale improvisée n'est calculée.

## Interface de la carte

Le sélecteur de calque permet de passer entre les indicateurs de sécurité, l'indice environnemental et les cinq variantes immobilières sans modifier l'année ni les autres paramètres de navigation.

Les prix et loyers utilisent une palette propre, distincte des couleurs de sécurité : six classes allant d'un bleu clair à un bleu profond puis au violet. Les classes suivent les mêmes bandes de percentiles nationaux que les autres calques :

- 0 à 20 ;
- 20 à 40 ;
- 40 à 60 ;
- 60 à 80 ;
- 80 à 95 ;
- 95 à 100.

Le gris signifie toujours que la valeur n'est pas affichable. Il ne signifie jamais que le prix ou le loyer est nul.

La légende nomme la métrique exacte, l'année, l'unité, la population de comparaison nationale et rappelle que la couleur est un percentile calculé par l'application.

Le détail d'une commune affiche :

- pour une vente : la médiane en `€/m²`, le nombre de mutations éligibles, l'année et la source DVF ;
- pour un loyer : l'estimation en `€/m²/mois`, le nombre d'observations communal, l'intervalle publié, l'année et la source ANIL ;
- pour une valeur grise : le motif de non-publication.

Une note méthodologique unique dans le panneau de carte précise que les prix d'achat sont des médianes calculées par l'application à partir de DVF et que les loyers sont des estimations de loyers d'annonce publiées par l'ANIL. Il n'est pas nécessaire de répéter cette note dans chaque infobulle.

## Import et actualisation

Des scripts indépendants prennent en charge :

- l'import DVF par millésime et révision ;
- l'import de la Carte des loyers par millésime ;
- le rafraîchissement des métriques immobilières dérivées.

Les imports passent par des tables de préparation et ne remplacent les données actives d'un millésime qu'après validation complète. En cas de téléchargement incomplet, de schéma inattendu, de volume manifestement anormal ou d'échec du calcul dérivé, les anciennes données restent servies.

L'idempotence repose sur le couple source/millésime/révision et sur les identifiants naturels des observations. Relancer un même import ne crée pas de doublon.

DVF étant révisé semestriellement, l'automatisation vérifie les ressources de toutes les années encore publiées, et pas seulement le dernier millésime. Une modification d'URL, de date de révision ou d'empreinte déclenche la reprise du millésime concerné.

La Carte des loyers est contrôlée annuellement. Lorsqu'un nouveau millésime apparaît, il est importé avec les types appartement et maison disponibles dans la publication.

L'orchestrateur annuel existant appelle ces imports sans coupler leur réussite à celle des imports SSMSI : une indisponibilité temporaire d'une source immobilière est signalée mais ne doit ni invalider les données officielles déjà actives ni corrompre un autre domaine. Les options de simulation, les journaux structurés et les rapports d'exécution suivent les conventions de l'orchestrateur actuel.

L'ajout d'une nouvelle année ne requiert aucune modification du frontend : les années disponibles proviennent des données importées.

## Vérifications

### Base et imports

- migration neuve et mise à niveau d'une base existante ;
- conservation exacte des champs officiels utilisés ;
- import idempotent et remplacement d'une révision sans doublon ;
- rejet atomique d'un fichier partiel ou d'un schéma inattendu ;
- maintien des anciennes données actives après un échec ;
- détection d'une révision DVF portant sur une année antérieure.

### Calcul DVF

- regroupement correct des lignes d'une mutation ;
- traitement des dépendances sans multiplier les logements ;
- exclusion des mutations comportant plusieurs logements principaux ;
- exclusion des valeurs ou surfaces absentes, nulles ou négatives ;
- exclusion stricte au-dessus de `100 000 €/m²` ;
- médianes correctes pour des effectifs pairs et impairs ;
- seuil de cinq mutations, y compris la frontière exacte ;
- médiane « tous logements » calculée sur les mutations, pas sur les médianes par type ;
- percentile limité aux communes publiables du même millésime et du même type.

### Qualité des loyers

- acceptation exacte à 30 observations et `R² = 0,5` ;
- exclusion d'une prédiction issue d'une maille non communale ;
- exclusion d'une estimation ou d'un intervalle invalide ;
- motifs distincts pour absence, année indisponible et qualité insuffisante ;
- percentile limité aux communes affichables comparables.

### API et interface

- validation des critères, types de logement et années ;
- stabilité des réponses des calques de sécurité existants ;
- rendu gris pour toute valeur non affichable ;
- palette, légende, unité, source et infobulle adaptées au calque ;
- chargement limité à l'emprise visible au niveau communal ;
- marqueurs régionaux et départementaux neutres ;
- absence de requêtes concurrentes obsolètes écrasant le dernier état ;
- contrôle visuel desktop et mobile de chaque variante.

### Contrôle global

Exécuter les tests ciblés, la suite complète, le typecheck et le build. Contrôler localement le passage successif d'un calque de sécurité à un prix d'achat puis à un loyer, avec une commune publiée, une commune sous le seuil de qualité et une zone non couverte.

## Hors périmètre

- score combinant criminalité et immobilier ;
- rendement locatif, mensualités ou simulation financière ;
- estimation prédictive d'un bien particulier ;
- données à l'adresse, à la parcelle ou affichage des transactions individuelles ;
- loyers réellement signés ou annonces meublées ;
- remplacement des données manquantes par une moyenne voisine ;
- agrégats régionaux ou départementaux improvisés ;
- carte choroplèthe communale à base de polygones.

Aucun commit n'est demandé.
