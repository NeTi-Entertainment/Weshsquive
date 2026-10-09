# Property Market Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter à la carte nationale des calques communaux annuels de prix d'achat médians DVF et de loyers d'annonce estimés ANIL, séparés par type de logement et assortis de règles strictes de publication.

**Architecture:** Conserver les champs officiels importés dans deux tables propres, puis produire dans une table dérivée transactionnelle les valeurs affichables, statuts de qualité et percentiles nationaux. Étendre uniquement l'API cartographique et ses composants pour lire ces métriques dans l'emprise visible ; les marqueurs régionaux et départementaux restent des repères neutres. Brancher enfin les deux sources sur l'orchestrateur annuel, avec détection des révisions et maintien de l'ancienne version en cas d'échec.

**Tech Stack:** PostgreSQL 16, PostGIS, PowerShell, Next.js 16, React 19, TypeScript 5.9, Zod, Leaflet, Vitest.

**Spec:** `docs/superpowers/specs/2026-10-09-property-market-map-design.md`

## Global Constraints

- Les champs officiels DVF et ANIL restent séparés des médianes, statuts, couleurs et percentiles calculés par l'application.
- Une donnée absente, non couverte ou insuffisamment fiable reste `NULL` et grise ; elle ne devient jamais zéro.
- Un prix DVF n'est affichable qu'à partir de 5 mutations éligibles pour la commune, l'année et le type sélectionné.
- Un loyer ANIL n'est affichable que pour une estimation communale directe avec `nbobs_com >= 30`, `R² ajusté >= 0,5` et un intervalle valide.
- Le calque de vente accepte `all`, `apartment` et `house`; le calque de location accepte uniquement `apartment` et `house`.
- Les groupes régionaux et départementaux restent neutres ; aucune moyenne territoriale immobilière n'est inventée.
- L'année globale de l'application est utilisée sans repli silencieux vers un autre millésime.
- La mise à jour d'une source ou d'une métrique est atomique et laisse l'ancienne version lisible en cas d'échec.
- Les sources restent gratuites et publiques ; aucun service cartographique ou immobilier payant n'est ajouté.
- Aucun commit ne doit être créé.

## Review Focus

- Une mutation DVF répétée sur plusieurs lignes, parcelles ou dépendances doit compter une seule fois, tandis qu'une mutation avec plusieurs logements principaux doit être exclue : couvert par les fixtures de la tâche 2.
- Une révision DVF d'une année antérieure doit remplacer atomiquement cette année sans toucher aux autres millésimes : couvert par les tests d'idempotence des tâches 2 et 7.
- Les décimales françaises, cellules vides, valeurs non finies et variantes d'encodage ne doivent ni casser l'import ni produire des zéros : couvert par les fixtures des tâches 2 et 3.
- Une année ou une commune sans métrique doit être renvoyée explicitement comme indisponible et rester grise, sans reprendre la dernière année connue : couvert par les tests API et UI des tâches 5 et 6.
- Un déplacement de carte ou changement de calque rapide ne doit pas laisser une ancienne réponse réseau remplacer le dernier état demandé : couvert par le test de requêtes concurrentes de la tâche 6.

---

### Task 1: Schéma immobilier et calcul dérivé transactionnel

**Files:**
- Create: `db/migrations/005_property_market_layers.sql`
- Create: `db/refresh_property_market_metrics.sql`
- Create: `scripts/refresh_property_market_metrics.ps1`
- Create: `scripts/test_property_market_metrics.ps1`
- Modify: `scripts/apply_migrations.ps1`
- Modify: `scripts/test_database_schema.ps1`

**Interfaces:**
- Consumes: `cities(insee_code, department_code)` et `import_batches(id, source_system, source_year, metadata)`.
- Produces: tables `property_sale_observations`, `property_rent_observations`, `property_market_metrics` et fonction SQL `refresh_property_market_metrics(target_year smallint)`.
- Produces: script `refresh_property_market_metrics.ps1 -Year <int>` pour reconstruire un millésime hors import.

- [ ] **Step 1: Étendre le test de schéma avec les nouvelles tables et contraintes**

Dans `scripts/test_database_schema.ps1`, vérifier les trois tables, leurs clés étrangères, les clés d'idempotence, les index de lecture `(year, metric_kind, property_type, city_insee_code)` et les contraintes suivantes : valeurs officielles positives lorsqu'elles existent, types autorisés, combinaison `rent/all` interdite et percentile dérivé borné entre 0 et 1.

- [ ] **Step 2: Exécuter le test de schéma et constater l'échec**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_database_schema.ps1`

Expected: FAIL parce que la migration `005_property_market_layers.sql` et les trois tables n'existent pas.

- [ ] **Step 3: Écrire la migration additive**

Créer les contrats SQL suivants dans `005_property_market_layers.sql` :

- `property_sale_observations(source_system text, source_year smallint, mutation_id text, city_insee_code varchar(5), mutation_date date, mutation_nature text, property_type text, sale_value numeric, built_area numeric, import_batch_id bigint, imported_at timestamptz)` avec clé primaire `(source_system, source_year, mutation_id)` ;
- `property_rent_observations(source_system text, source_year smallint, city_insee_code varchar(5), property_type text, estimated_rent_per_m2 numeric, lower_bound_per_m2 numeric, upper_bound_per_m2 numeric, prediction_type text, commune_observation_count integer, grid_observation_count integer, adjusted_r2 numeric, import_batch_id bigint, imported_at timestamptz)` avec clé primaire `(source_system, source_year, city_insee_code, property_type)` ;
- `property_market_metrics(city_insee_code varchar(5), year smallint, metric_kind text, property_type text, value_per_m2 numeric, lower_bound_per_m2 numeric, upper_bound_per_m2 numeric, sample_count integer, national_percentile numeric, display_status text, source_system text, import_batch_id bigint, calculated_at timestamptz)` avec clé primaire `(city_insee_code, year, metric_kind, property_type)`.

Limiter `display_status` à `published`, `source-uncovered`, `no-data`, `insufficient-sample`, `non-communal-estimate`, `insufficient-quality` et `invalid-value`. Un statut `published` exige une valeur et un percentile ; tous les autres exigent `value_per_m2 IS NULL` et `national_percentile IS NULL`.

- [ ] **Step 4: Écrire d'abord les fixtures SQL du calcul dérivé**

Dans `scripts/test_property_market_metrics.ps1`, créer une base isolée, appliquer les migrations, insérer des communes et des observations contrôlées, puis affirmer : médianes impaires et paires, seuil exact de 5, médiane `all` calculée sur les mutations, percentile limité aux lignes publiées, départements `57`, `67`, `68`, `976` non couverts par DVF, Mayotte non couverte par ANIL, critères ANIL exacts à 30 observations et `R² = 0,5`, et motifs distincts pour prédiction non communale ou qualité insuffisante.

- [ ] **Step 5: Exécuter le test de métriques et constater l'échec**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_property_market_metrics.ps1`

Expected: FAIL parce que `refresh_property_market_metrics(smallint)` n'existe pas.

- [ ] **Step 6: Implémenter `refresh_property_market_metrics(target_year smallint)`**

La fonction supprime puis reconstruit, dans la transaction appelante, les cinq lignes potentielles par commune pour l'année : `sale/all`, `sale/apartment`, `sale/house`, `rent/apartment`, `rent/house`. Utiliser `percentile_cont(0.5)` pour les ventes et `percent_rank()` uniquement sur les lignes publiables ; reprendre directement la valeur ANIL et ses bornes pour les loyers. Créer `db/refresh_property_market_metrics.sql` comme enveloppe psql transactionnelle recevant `year`, et le script PowerShell qui la lance sous verrou consultatif.

- [ ] **Step 7: Initialiser les métriques immobilières après migration si des observations existent**

Dans `scripts/apply_migrations.ps1`, détecter les années distinctes des deux tables d'observations et appeler le script de rafraîchissement pour chacune uniquement lorsque la migration vient d'être appliquée ou qu'aucune métrique correspondante n'existe.

- [ ] **Step 8: Vérifier le schéma et le calcul**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_database_schema.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_property_market_metrics.ps1
```

Expected: PASS pour les deux scripts.

### Task 2: Import idempotent des ventes DVF

**Files:**
- Create: `scripts/import_property_sales_dvf.ps1`
- Create: `scripts/test_import_property_sales_dvf.ps1`

**Interfaces:**
- Consumes: fichiers CSV compressés normalisés de `https://files.data.gouv.fr/geo-dvf/`, une `Year`, une collection optionnelle de `SourceUrls`, et la fonction SQL `refresh_property_market_metrics(smallint)` de la tâche 1.
- Produces: observations `property_sale_observations` pour `source_system = 'dvf-geolocated'`, un `import_batches` terminé et les métriques de vente reconstruites dans la même transaction.
- Parameters: `-Year`, `-SourceUrls`, `-SourceLastModified`, `-SourceManifestHash`, plus les paramètres PostgreSQL habituels.

- [ ] **Step 1: Écrire les fixtures d'import DVF**

Dans `scripts/test_import_property_sales_dvf.ps1`, générer de petits CSV `.gz` comportant les colonnes `id_mutation`, `date_mutation`, `nature_mutation`, `valeur_fonciere`, `code_commune`, `id_local`, `type_local`, `surface_reelle_bati`. Couvrir une ligne simple, une duplication parcellaire, une dépendance, deux logements principaux, une mutation multicommunale, une surface nulle, une décimale à virgule, un prix supérieur à `100 000 €/m²`, un code INSEE inconnu et un fichier partiel au schéma invalide. Affirmer que la valeur extrême reste conservée avec ses champs officiels mais n'entre pas dans la médiane.

- [ ] **Step 2: Exécuter le test et constater l'échec**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_import_property_sales_dvf.ps1`

Expected: FAIL parce que l'importeur DVF n'existe pas.

- [ ] **Step 3: Implémenter la résolution et la validation des sources**

Dans `import_property_sales_dvf.ps1`, accepter des chemins locaux pour les tests et des URL HTTPS `files.data.gouv.fr` pour la production. Télécharger en répertoire temporaire, vérifier gzip, en-têtes exacts, année des dates, présence de lignes et couverture minimale en production ; normaliser l'encodage sans modifier les valeurs de source.

- [ ] **Step 4: Implémenter la sélection des mutations éligibles**

Charger toutes les lignes en table temporaire PostgreSQL, regrouper par `id_mutation`, compter les `id_local` résidentiels distincts, ignorer les dépendances comme logement principal, et ne retenir que les mutations ayant un appartement ou une maison unique dans une seule commune. Exiger une nature parmi `Vente`, `Vente en l'état futur d'achèvement`, `Adjudication`, une valeur et une surface cohérentes et positives. Conserver les champs officiels d'une mutation dont le prix dérivé dépasse `100 000 €/m²`; c'est `refresh_property_market_metrics` qui l'exclut de la médiane, sans écrire le prix dérivé dans la table officielle.

- [ ] **Step 5: Rendre le remplacement atomique et idempotent**

Dans une transaction unique, créer le lot d'import, remplacer seulement `source_system = 'dvf-geolocated' AND source_year = Year`, insérer les mutations retenues, appeler `refresh_property_market_metrics(Year)`, puis valider. Stocker dans `import_batches.metadata` les URL, le manifeste de ressources, son empreinte, la révision de catalogue, les colonnes, volumes lus/retenus/exclus et les motifs d'exclusion. Toute erreur annule observations, lot et métriques.

- [ ] **Step 6: Vérifier le premier import, la relance et une révision**

Le test doit affirmer qu'une relance identique conserve les mêmes lignes sans doublon, puis qu'une fixture révisée remplace uniquement l'année demandée, recalcule sa médiane et laisse une autre année intacte.

- [ ] **Step 7: Exécuter le test DVF**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_import_property_sales_dvf.ps1`

Expected: PASS, y compris les cas de duplication, multi-logement, virgule décimale, révision et rollback.

### Task 3: Import idempotent des loyers ANIL

**Files:**
- Create: `scripts/import_property_rents_anil.ps1`
- Create: `scripts/test_import_property_rents_anil.ps1`

**Interfaces:**
- Consumes: ressource communale CSV de la Carte des loyers ANIL, `-Year`, `-RentFileUrl`, `-SourceLastModified`, et `refresh_property_market_metrics(smallint)`.
- Produces: observations `property_rent_observations` pour `source_system = 'anil-rent-map'`, un lot d'import terminé et les métriques de location reconstruites dans la transaction.

- [ ] **Step 1: Écrire les fixtures d'import ANIL**

Créer dans `scripts/test_import_property_rents_anil.ps1` un CSV minimal reprenant les colonnes officielles de code commune, type de logement, `loypredm2`, bornes, `TYPPRED`, `nbobs_com`, `nbobs_mail` et `R2_adj`. Inclure appartements, maisons, catégories T1-T2/T3+, estimation communale, estimation de maille, seuils juste sous et exactement sur 30/0,5, cellules vides, décimales à virgule, intervalle inversé et commune inconnue.

- [ ] **Step 2: Exécuter le test et constater l'échec**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_import_property_rents_anil.ps1`

Expected: FAIL parce que l'importeur ANIL n'existe pas.

- [ ] **Step 3: Implémenter la validation et le mapping ANIL**

Accepter un fichier local ou une URL HTTPS officielle data.gouv.fr, valider l'en-tête et le millésime, puis mapper uniquement les lignes « appartements ensemble » et « maisons » vers `apartment` et `house`. Conserver les valeurs et informations de qualité officielles, y compris celles qui seront grisées ; ne pas importer les sous-catégories T1-T2/T3+ dans les deux calques demandés.

- [ ] **Step 4: Rendre l'import atomique et idempotent**

Dans une transaction, remplacer uniquement l'année ANIL visée, insérer le lot et les observations, appeler `refresh_property_market_metrics(Year)`, puis valider. Enregistrer URL, identifiant de ressource, révision, empreinte, colonnes, volumes et anomalies dans `import_batches.metadata`. Un fichier incomplet, une année incohérente ou un volume anormal doit annuler la transaction.

- [ ] **Step 5: Vérifier les seuils et les données conservées**

Affirmer que les observations de maille et de faible qualité sont conservées dans la table officielle mais produisent une métrique `NULL` avec le bon statut ; vérifier qu'un vrai seuil `30` et `0,5` est publié, qu'un intervalle invalide est grisé et qu'aucune cellule vide n'est transformée en zéro.

- [ ] **Step 6: Exécuter le test ANIL**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_import_property_rents_anil.ps1`

Expected: PASS pour l'import, la relance, la révision et le rollback.

### Task 4: Contrat partagé et lecture serveur des métriques immobilières

**Files:**
- Create: `src/shared/property-market.ts`
- Create: `src/server/property-market.ts`
- Create: `tests/property-market.test.ts`

**Interfaces:**
- Produces: `PropertyMarketMetricKind = "sale" | "rent"`, `SalePropertyType = "all" | "apartment" | "house"`, `RentPropertyType = "apartment" | "house"`, `PropertyMarketDisplayStatus`, `PropertyMarketMetric`.
- Produces: `buildPropertyMarketSelection(params: PropertyMarketSelectionParams, yearPlaceholder: string): SqlFragment` et `mapPropertyMarketMetric(row: RawPropertyMarketColumns, selection): PropertyMarketMetric`.
- Consumes: `property_market_metrics` de la tâche 1.

- [ ] **Step 1: Écrire les tests de contrat et de mapping**

Dans `tests/property-market.test.ts`, fixer les unions de types, les libellés de statut en français et le mapping des nombres PostgreSQL sous forme de chaînes décimales. Tester une ligne publiée, chaque statut gris, une ligne absente dans une année pourtant disponible et une année entièrement indisponible.

- [ ] **Step 2: Exécuter le test et constater l'échec**

Run: `npm test -- tests/property-market.test.ts`

Expected: FAIL sur les modules manquants.

- [ ] **Step 3: Implémenter les types partagés**

Dans `src/shared/property-market.ts`, définir les types exacts et un objet `PropertyMarketMetric` contenant `kind`, `propertyType`, `valuePerM2`, `lowerBoundPerM2`, `upperBoundPerM2`, `sampleCount`, `nationalPercentile`, `status`, `sourceSystem`, `sourceYear`. `PropertyMarketDisplayStatus` reprend les statuts persistés et ajoute le statut de réponse `year-unavailable`, qui n'est jamais écrit dans `property_market_metrics`.

- [ ] **Step 4: Implémenter le fragment SQL et le mapping serveur**

Dans `src/server/property-market.ts`, produire une jointure paramétrée sur année, nature et type, plus un indicateur d'existence du millésime. Une absence de ligne devient `no-data` si le millésime existe et `year-unavailable` sinon ; aucune valeur d'une autre année n'est consultée.

- [ ] **Step 5: Exécuter le test serveur ciblé**

Run: `npm test -- tests/property-market.test.ts`

Expected: PASS.

### Task 5: Extension de l'API de carte nationale

**Files:**
- Modify: `src/server/national-map.ts`
- Modify: `app/api/cities/map/route.ts`
- Modify: `tests/national-map.test.ts`
- Modify: `tests/cities-map-route.test.ts`

**Interfaces:**
- Consumes: `buildPropertyMarketSelection` et `mapPropertyMarketMetric` de la tâche 4.
- Produces: critères API `salePrice` et `rentPrice`, paramètre `marketPropertyType`, et champ `propertyMarket: PropertyMarketMetric | null` sur `NationalMapPoint`.
- Préserve: forme et comportement des critères `comparativeIndex`, `categoryRate`, `environmentalRisk`.

- [ ] **Step 1: Écrire les tests de validation des paramètres**

Ajouter à `tests/national-map.test.ts` les cas valides `salePrice/all`, `salePrice/apartment`, `salePrice/house`, `rentPrice/apartment`, `rentPrice/house`; rejeter l'absence de type, `rentPrice/all`, un type inconnu et les paramètres immobiliers avec un critère non immobilier.

- [ ] **Step 2: Écrire les tests SQL et mapping**

Affirmer que la requête communale joint `property_market_metrics` sur la même année/type, conserve les filtres existants et la restriction d'emprise, et ne joint pas ces métriques aux niveaux région/département. Tester la réponse publiée, grise et l'année indisponible sans changement du résultat des trois anciens critères.

- [ ] **Step 3: Exécuter les tests et constater l'échec**

Run: `npm test -- tests/national-map.test.ts tests/cities-map-route.test.ts`

Expected: FAIL car les nouveaux critères sont rejetés.

- [ ] **Step 4: Étendre Zod, les paramètres et le point cartographique**

Ajouter `criterion: "salePrice" | "rentPrice"` et `marketPropertyType` avec les raffinements croisés exacts. N'ajouter la jointure immobilière que pour une requête communale portant sur un critère immobilier ; pour les groupes, continuer à renvoyer les repères neutres sans agrégat.

- [ ] **Step 5: Préserver la stabilité de la route**

La route conserve ses réponses `400` Zod et `500`; elle renvoie le champ immobilier dans le résultat JSON sans altérer les filtres ni les champs existants.

- [ ] **Step 6: Exécuter les tests API**

Run: `npm test -- tests/property-market.test.ts tests/national-map.test.ts tests/cities-map-route.test.ts`

Expected: PASS.

### Task 6: Palette, contrôles et détails immobiliers sur la carte

**Files:**
- Create: `src/client/property-market-ui.ts`
- Create: `tests/property-market-ui.test.ts`
- Modify: `src/client/france-map-ui.ts`
- Modify: `tests/france-map-ui.test.ts`
- Modify: `app/france-map.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: `PropertyMarketMetric` et les nouveaux critères API.
- Produces: `getPropertyMarketColor(metric)`, `formatPropertyMarketValue(metric)`, `propertyMarketStatusLabel(status)` et les variantes de `NationalMapCriterion` correspondantes.

- [ ] **Step 1: Écrire les tests de palette et de formatage**

Dans `tests/property-market-ui.test.ts`, vérifier six couleurs distinctes bleu clair, cyan/bleu, bleu profond et violet pour les bandes `[0,.2)`, `[.2,.4)`, `[.4,.6)`, `[.6,.8)`, `[.8,.95)`, `[.95,1]`; tous les statuts non publiés utilisent `#7b8794`. Vérifier `€/m²`, `€/m²/mois`, nombres français, intervalle ANIL et motifs gris.

- [ ] **Step 2: Étendre les tests d'URL et de concurrence**

Dans `tests/france-map-ui.test.ts`, affirmer que `buildNationalMapUrl` sérialise `salePrice/house` et `rentPrice/apartment`, ne conserve aucun ancien paramètre de catégorie/rayon, et colore toujours les groupes avec `#526a7b`. Ajouter ou adapter le test du chargeur pour prouver qu'une réponse immobilière ancienne, résolue après un changement de calque ou d'emprise, est ignorée via le mécanisme `AbortController`/identifiant de requête existant.

- [ ] **Step 3: Exécuter les tests et constater l'échec**

Run: `npm test -- tests/property-market-ui.test.ts tests/france-map-ui.test.ts tests/latest-request.test.ts`

Expected: FAIL sur les nouveaux critères et helpers.

- [ ] **Step 4: Implémenter les helpers et la sérialisation**

Ajouter à `NationalMapCriterion` les variantes `{ type: "salePrice"; propertyType: SalePropertyType }` et `{ type: "rentPrice"; propertyType: RentPropertyType }`. Utiliser `propertyMarket.nationalPercentile` uniquement lorsque le statut est `published`; ne jamais déduire une couleur du prix brut.

- [ ] **Step 5: Ajouter les contrôles de calque**

Dans `app/france-map.tsx`, ajouter les choix « Prix d'achat médian » et « Loyer d'annonce estimé », puis un contrôle de type adapté : tous logements/appartements/maisons pour l'achat, appartements/maisons pour la location. Conserver l'année globale, le zoom et l'emprise lors d'un changement de calque.

- [ ] **Step 6: Adapter la légende et les infobulles**

Afficher la palette immobilière séparée, l'unité et le rappel « percentile national calculé par l'application ». Dans l'infobulle, afficher médiane et nombre de mutations DVF, ou estimation, observations et intervalle ANIL ; pour une valeur grise, afficher seulement le motif compréhensible. Ajouter une note méthodologique unique au panneau, pas à chaque point.

- [ ] **Step 7: Ajuster les styles responsive**

Dans `app/globals.css`, conserver les dimensions stables des contrôles, permettre leur retour à la ligne sur mobile et ajouter les classes de palette sans modifier les couleurs des indices de sécurité.

- [ ] **Step 8: Exécuter les tests UI ciblés**

Run: `npm test -- tests/property-market-ui.test.ts tests/france-map-ui.test.ts tests/latest-request.test.ts`

Expected: PASS.

### Task 7: Découverte des publications et orchestration annuelle

**Files:**
- Modify: `scripts/annual_import_core.psm1`
- Modify: `scripts/update_official_data.ps1`
- Modify: `scripts/test_annual_import_core.ps1`
- Modify: `docs/imports-annuels.md`

**Interfaces:**
- Produces: `Get-DvfReleases`, `Get-LatestAnilRentRelease`, et propriétés `ImportDvfYears`, `ImportRentYear`, `RefreshPropertyMarketYears` dans `New-AnnualImportPlan`.
- Consumes: API data.gouv du jeu DVF géolocalisé, recherche data.gouv des Cartes des loyers ANIL, métadonnées `import_batches`, et scripts des tâches 2 et 3.

- [ ] **Step 1: Écrire les fixtures de catalogues**

Dans `scripts/test_annual_import_core.ps1`, ajouter des catalogues synthétiques avec plusieurs années DVF, une révision d'une année antérieure, URL non approuvée, ressource non CSV, plusieurs publications ANIL et titre trompeur. Affirmer la sélection exclusive des ressources officielles attendues et la conservation séparée du millésime et de la date de révision.

- [ ] **Step 2: Écrire les tests de planification**

Tester : aucun changement, nouveau millésime DVF, révision d'un seul ancien millésime, nouveau millésime ANIL, échec précédent laissant les métriques obsolètes, et indisponibilité immobilière n'empêchant pas la planification SSMSI/INSEE. Le plan doit retourner précisément les années immobilières à importer.

- [ ] **Step 3: Exécuter le test et constater l'échec**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_annual_import_core.ps1`

Expected: FAIL car les fonctions et propriétés immobilières n'existent pas.

- [ ] **Step 4: Implémenter la découverte des sources**

`Get-DvfReleases` accepte les ressources du catalogue DVF géolocalisé, n'autorise que `https://files.data.gouv.fr/geo-dvf/`, regroupe les ressources départementales par année et calcule un manifeste stable à comparer aux métadonnées importées. `Get-LatestAnilRentRelease` sélectionne le dernier jeu publié par l'organisme attendu, reconnaît la ressource communale CSV et rejette toute origine ou structure ambiguë.

- [ ] **Step 5: Étendre `New-AnnualImportPlan`**

Comparer chaque manifeste DVF encore diffusé aux lots terminés correspondants afin de détecter une révision de n'importe quelle année disponible. Comparer séparément l'ANIL par millésime, URL et date de modification. Ne pas rendre `HasUpdates` dépendant de la disponibilité instantanée d'une source qui n'a aucune nouvelle publication.

- [ ] **Step 6: Brancher les imports dans l'orchestrateur**

Dans `update_official_data.ps1`, ajouter les URL de catalogues configurables, inclure l'état immobilier local, journaliser le plan, respecter `-PlanOnly`, puis invoquer les scripts DVF et ANIL pour les années planifiées. Capturer les erreurs immobilières par domaine : laisser les données actives intactes, continuer les domaines indépendants, terminer avec un rapport d'échec non ambigu si une mise à jour planifiée n'a pas abouti.

- [ ] **Step 7: Documenter l'exploitation**

Dans `docs/imports-annuels.md`, ajouter les sources, paramètres manuels, règles de révision DVF, seuils de publication, commandes de reprise et requêtes de contrôle des derniers lots. Préciser que DVF ne couvre pas `57`, `67`, `68`, `976` et que l'ANIL ne couvre pas Mayotte.

- [ ] **Step 8: Exécuter les tests d'automatisation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_annual_import_core.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/update_official_data.ps1 -PlanOnly
```

Expected: tests PASS ; le mode aperçu décrit les imports sans modifier les lots ni les métriques.

### Task 8: Chargement local 2025 et validation de bout en bout

**Files:**
- Modify only if diagnostics reveal a defect: files owned by Tasks 1-7

**Interfaces:**
- Consumes: migration, importeurs, métriques, API et UI terminés.
- Produces: base locale migrée avec DVF 2025 et ANIL 2025, application testable sur `http://localhost:3000/`.

- [ ] **Step 1: Exécuter tous les tests avant de toucher à la base locale**

Run:

```powershell
npm test
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_database_schema.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_property_market_metrics.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_import_property_sales_dvf.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_import_property_rents_anil.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_annual_import_core.ps1
npm run typecheck
npm run build
```

Expected: toutes les commandes PASS.

- [ ] **Step 2: Appliquer la migration locale**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/apply_migrations.ps1`

Expected: `005_property_market_layers.sql` appliquée une fois, sans altération des tables SSMSI.

- [ ] **Step 3: Importer les publications 2025 officielles**

Résoudre les ressources courantes via l'orchestrateur, puis lancer les importeurs DVF 2025 et ANIL 2025 avec les URL et métadonnées validées. Ne pas ajouter d'année absente du catalogue et ne jamais contourner un échec de validation de source.

Expected: lots `dvf-geolocated` et `anil-rent-map` terminés, métriques 2025 présentes pour les cinq variantes.

- [ ] **Step 4: Contrôler les données en base**

Exécuter des requêtes de contrôle pour vérifier : effectifs par source/type/statut, absence de doublons, absence de valeurs publiées sous les seuils, percentiles bornés, gris pour les territoires non couverts et correspondance de plusieurs médianes avec un recalcul direct sur les observations retenues.

- [ ] **Step 5: Mesurer la requête cartographique**

Lancer `EXPLAIN (ANALYZE, BUFFERS)` sur une emprise communale dense pour chacun des deux genres de métrique. Vérifier l'utilisation de l'index immobilier et l'absence de scan national ou de requête par commune ; documenter toute mesure dépassant nettement les temps des calques actuels avant de poursuivre.

- [ ] **Step 6: Démarrer l'application et contrôler les parcours**

Run: `npm run dev`

Ouvrir `http://localhost:3000/` et vérifier sur desktop puis mobile : passage sécurité → achat → location, cinq variantes, changement d'année, déplacement/zoom rapide, commune publiée, échantillon insuffisant, estimation non communale, Mayotte et zone DVF non couverte. Confirmer que les groupes restent neutres et que seules les communes visibles sont rendues.

- [ ] **Step 7: Rejouer la vérification finale**

Run:

```powershell
npm test
npm run typecheck
npm run build
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/update_official_data.ps1 -PlanOnly
```

Expected: PASS, aucune régression des calques de sécurité, et le mode aperçu considère les publications 2025 déjà importées comme à jour.
