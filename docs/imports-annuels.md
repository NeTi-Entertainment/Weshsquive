# Imports officiels annuels

`scripts/update_official_data.ps1` compare les catalogues publics SSMSI, Insee, DVF géolocalisé et Carte des loyers aux dernières sources enregistrées dans PostgreSQL. Il importe une année nouvelle ou une ressource révisée, synchronise si nécessaire les communes et leurs coordonnées, puis reconstruit les métriques dérivées concernées. Pour une révision, il remplace transactionnellement les observations de l'année et de la source concernées ; les autres années et sources restent intactes. Des contrôles bloquent les fichiers vides, incomplets ou de structure inattendue avant ce remplacement.

Les sources immobilières utilisées sont :

- les [Demandes de valeurs foncières géolocalisées](https://www.data.gouv.fr/datasets/demandes-de-valeurs-foncieres-geolocalisees/) diffusées par data.gouv.fr pour les prix d'achat ;
- la [Carte des loyers](https://www.data.gouv.fr/datasets/carte-des-loyers-indicateurs-de-loyers-dannonce-par-commune-en-2025/) produite par l'ANIL et le ministère chargé du logement pour les loyers d'annonce estimés.

DVF révise plusieurs fois les millésimes encore diffusés. L'orchestrateur compare donc le manifeste de chaque année du catalogue, et pas seulement l'année la plus récente. Une révision réimporte uniquement le millésime concerné. DVF ne couvre pas les départements `57`, `67`, `68` et `976`. La Carte des loyers ne couvre pas Mayotte.

Avant toute exécution réelle, l'aperçu permet de vérifier les millésimes et les changements détectés :

```powershell
pwsh -NoProfile -File scripts/update_official_data.ps1 -PlanOnly
```

Pour lancer le contrôle et les imports nécessaires manuellement :

```powershell
pwsh -NoProfile -File scripts/update_official_data.ps1
```

Une première exécution peut réimporter le dernier millésime déjà présent si son URL ou sa date de modification catalogue n'était pas conservée dans ses métadonnées. Les importeurs sont idempotents ; les exécutions suivantes n'écrivent rien si l'année, l'URL et la révision officielle sont inchangées.

Si les imports bruts aboutissent mais que le rafraîchissement statistique échoue, le prochain contrôle détecte que l'instantané actif précède les derniers imports et relance uniquement ce rafraîchissement. Une erreur de copie vers Docker arrête immédiatement l'import avant l'appel à PostgreSQL.

Les domaines immobiliers sont indépendants des imports SSMSI et Insee. Une indisponibilité DVF ou ANIL est journalisée, les autres domaines planifiés continuent, puis la commande termine en erreur afin que le planificateur signale clairement la mise à jour incomplète. Les importeurs immobiliers conservent la version précédente si un téléchargement, une validation ou le calcul dérivé échoue.

## Règles de publication immobilière

Un prix d'achat est affiché uniquement à partir de cinq mutations résidentielles éligibles pour la commune, l'année et le type de logement. La valeur affichée est une médiane calculée par l'application à partir des observations DVF, pas un prix communal officiel publié directement par DVF.

Un loyer est affiché uniquement si l'ANIL fournit une estimation communale directe, au moins 30 observations communales, un `R²` ajusté d'au moins `0,5` et un intervalle valide. La valeur reste une estimation de loyer d'annonce publiée par l'ANIL. Les données absentes, hors couverture ou sous les seuils restent `NULL` et grises sur la carte ; elles ne deviennent jamais zéro.

## Reprise manuelle ciblée

Pour une reprise distante, utiliser l'orchestrateur : il construit la liste nationale complète des départements couverts et refuse tout sous-ensemble qui remplacerait silencieusement une année entière.

```powershell
pwsh -NoProfile -File scripts/update_official_data.ps1 -PlanOnly
pwsh -NoProfile -File scripts/update_official_data.ps1
```

L'importeur DVF peut aussi recevoir un ou plusieurs fichiers locaux pour une reprise hors ligne contrôlée. Ce mode remplace toujours le millésime national complet : les fichiers locaux doivent donc représenter volontairement tout le périmètre à conserver.

```powershell
pwsh -NoProfile -File scripts/import_property_sales_dvf.ps1 -Year 2025 -SourceUrls @(
  'C:\imports\dvf-2025-01.csv.gz',
  'C:\imports\dvf-2025-02.csv.gz'
  # ...tous les fichiers du périmètre national à conserver
)

pwsh -NoProfile -File scripts/import_property_rents_anil.ps1 `
  -Year 2025 `
  -ApartmentFileUrl '<URL CSV appartements data.gouv.fr>' `
  -HouseFileUrl '<URL CSV maisons data.gouv.fr>'

pwsh -NoProfile -File scripts/refresh_property_market_metrics.ps1 -Year 2025
```

Chaque lot DVF conserve l'empreinte SHA-256 de chaque ressource réellement téléchargée, un manifeste de contenu et l'empreinte de révision du catalogue. Chaque lot ANIL conserve séparément les empreintes des fichiers appartements et maisons ainsi qu'une empreinte commune de leurs métadonnées catalogue.

Les derniers lots et leurs métadonnées peuvent être contrôlés ainsi :

```powershell
docker exec -e PGPASSWORD=app_dev_password app-criminalite-db psql `
  -U app -d app_criminalite -c "select source_system, source_year, status, completed_at, metadata from import_batches where source_system in ('dvf-geolocated', 'anil-rent-map') order by id desc limit 20;"

docker exec -e PGPASSWORD=app_dev_password app-criminalite-db psql `
  -U app -d app_criminalite -c "select year, metric_kind, property_type, display_status, count(*) from property_market_metrics group by 1,2,3,4 order by 1,2,3,4;"
```

Le Planificateur de tâches Windows peut lancer un contrôle le premier jour de chaque mois à 08:00, uniquement lorsque l'utilisateur courant est connecté. Installation manuelle :

```powershell
pwsh -NoProfile -File scripts/install_annual_import_task.ps1
```

Retrait de la tâche :

```powershell
pwsh -NoProfile -File scripts/install_annual_import_task.ps1 -Remove
```

La tâche nécessite une session Windows ouverte et Docker Desktop disponible pour accéder au conteneur `app-criminalite-db`. Les journaux sont écrits dans `%LOCALAPPDATA%\AppCriminalite\logs`. Les URL de catalogue sont configurables avec `-SsmiDatasetApiUrl`, `-PopulationDatasetApiUrl`, `-DvfDatasetApiUrl` et `-AnilCatalogApiUrl`. Une ressource de format, d'année ou de couverture inattendue provoque un échec explicite ; une révision incomplète ne remplace pas l'année existante et l'ancien instantané statistique reste actif.
