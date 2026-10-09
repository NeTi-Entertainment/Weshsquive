# Carte nationale des communes

## Objectif

Ajouter une vraie vue cartographique nationale à l'application. Elle doit permettre de parcourir les communes françaises et leurs indicateurs sans charger ni dessiner toutes les communes lorsque la carte est dézoomée ou centrée sur une autre zone.

## Décisions produit

- Ajouter un mode « Carte » à côté du tableau principal, en réutilisant l'année, les filtres géographiques et les critères statistiques disponibles.
- Utiliser les tuiles OpenStreetMap et les coordonnées des centres communaux déjà conservées dans `cities.geom`.
- Afficher une hiérarchie adaptée au zoom : régions à l'échelle nationale, départements à l'échelle intermédiaire, puis communes à une échelle rapprochée.
- À l'échelle communale, ne demander et ne rendre que les communes dans l'emprise visible. Une vue centrée sur Bordeaux ne charge ni ne dessine les communes de Marseille.
- Les marqueurs régionaux et départementaux servent uniquement à la navigation. Ils indiquent le nom du territoire et son nombre de communes, sans couleur statistique ni somme, moyenne ou score de criminalité.
- Les points communaux sont colorés selon l'indice comparatif de l'application ou le percentile du taux publié d'une catégorie, avec les cohortes et unités prévues par ces indicateurs. Les données absentes restent dans la couleur indisponible.
- Un clic sur une région ou un département zoome vers son emprise géographique ; un clic sur une commune ouvre sa fiche.
- L'indicateur environnemental reste disponible à l'échelle des communes visibles, en requête groupée et avec ses statuts de couverture existants. Il n'est pas agrégé pour colorer un marqueur régional ou départemental.
- La carte demeure une carte de points sur un fond cartographique, pas une choroplèthe : le schéma ne contient que des points communaux et aucun contour officiel de commune, département ou région.

## Comportement cartographique

- La vue initiale cadre la France métropolitaine. Les territoires ultramarins restent accessibles via les filtres de région, qui recentrent la carte sur leur emprise au lieu de comprimer tous les territoires dans un cadrage illisible.
- La représentation dépend du zoom :
  - vue nationale : un marqueur de navigation par région ;
  - zoom intermédiaire : un marqueur de navigation par département ;
  - zoom rapproché : les communes géolocalisées dans l'emprise courante.
- Les seuils de zoom sont des constantes de présentation ajustables après vérification visuelle. La transition ne modifie jamais les statistiques.
- Les requêtes sont annulées ou ignorées lorsqu'une emprise plus récente est demandée, afin qu'une réponse réseau ancienne ne remplace pas la carte courante.
- Les changements d'emprise et de zoom ne mettent à jour que la couche cartographique ; ils ne réinitialisent pas les filtres statistiques sélectionnés.

## Données et API

- Créer une API cartographique dédiée, paramétrée par l'année, le niveau de zoom, l'emprise, l'indicateur et les filtres géographiques pertinents.
- Utiliser PostGIS pour sélectionner les communes visibles et produire les groupes régionaux ou départementaux nécessaires à l'échelle courante.
- Lire les métriques dans l'instantané actif et transmettre le même `snapshot_id` aux éventuelles requêtes complémentaires de la couche environnementale.
- Pour les points communaux, retourner les coordonnées, les identifiants et noms territoriaux, les valeurs d'indicateur, les statuts de publication et les métadonnées d'unité/dénominateur utiles aux infobulles.
- Pour les groupes régionaux et départementaux, retourner uniquement les informations de navigation, les limites de cadrage et le décompte des communes ; aucun champ statistique agrégé n'est exposé.
- Les limites de cadrage des groupes sont calculées à partir des centres communaux membres. Elles ne sont pas présentées comme des géométries ou limites administratives officielles.

## Présentation

- Ajouter une commande visible pour passer du tableau à la carte et conserver les filtres de recherche pertinents lors du changement de vue.
- Réutiliser l'échelle colorée existante pour les points communaux et afficher explicitement « non disponible » lorsque l'indicateur ne peut pas être calculé.
- Les infobulles des communes présentent les valeurs officielles publiées et leur unité/base ; l'indice comparatif et l'indicateur environnemental sont identifiés comme calculs de l'application.
- Les marqueurs de groupes présentent seulement le nom du territoire, le nombre de communes et l'action de zoom.

## Hors périmètre

- Importer des contours GeoJSON ou produire une carte choroplèthe.
- Interpréter les marqueurs de groupe comme des indicateurs de risque ou de sûreté.
- Modifier les données brutes SSMSI, les formules de l'indice comparatif ou les règles de publication.
- Ajouter un service cartographique payant.

## Vérification attendue

- Tester le choix du niveau régional, départemental ou communal en fonction du zoom.
- Tester que le filtrage par emprise exclut les communes hors champ et que le changement rapide de vue n'affiche pas une ancienne réponse.
- Tester que les groupes ne produisent aucune statistique de criminalité agrégée et que les points conservent leurs unités, bases, statuts et couleurs actuels.
- Vérifier le comportement de la couche environnementale en requête groupée, ses statuts indisponibles et la cohérence de son instantané.
- Exécuter la suite de tests, le typecheck et le build, puis vérifier visuellement la carte aux niveaux France, département et commune sur desktop et mobile.
