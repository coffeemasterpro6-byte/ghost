# Ghost Gaming

Application Flutter de gestion de salle gaming, avec Supabase pour l’authentification et les données partagées.

## Démarrage

Le projet Supabase et sa clé publique `publishable` sont configurés par défaut dans l’application. Vous pouvez les remplacer au lancement si nécessaire :

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<public-publishable-key>
```

`SUPABASE_ANON_KEY` est également accepté pour les projets utilisant encore l’ancienne clé publique. N’intégrez jamais la clé `service_role` dans l’application.

Appliquez les scripts SQL dans l’ordre, depuis le SQL Editor Supabase :

1. `20260101000001_foundation.sql`
2. `20260101000002_catalog.sql`
3. `20260101000003_sessions.sql`
4. `20260101000004_auth_setup.sql`
5. `20260101000005_inventory.sql`
6. `20260101000006_pos_payments.sql`
7. `20260101000007_customer_qr_link.sql`
8. `20260101000008_staff_invitations.sql`
9. `20260101000009_customer_session_orders.sql`
10. `20260101000010_reservations.sql`
11. `20260101000011_expenses.sql`
12. `20260101000012_cash_shifts.sql`
13. `20260101000013_customer_wallet_credit.sql`
14. `20260101000014_session_wallet_credit_payments.sql`
15. `20260101000015_promotions.sql`
16. `20260101000016_loyalty_rewards.sql`
17. `20260101000017_memberships_packages.sql`
18. `20260101000018_customer_standalone_orders.sql`
19. `20260101000019_catalog_image_storage.sql`
20. `20260101000020_attach_pre_session_orders.sql`
21. `20260101000021_invoice_history_access.sql`
22. `20260101000022_post_game_configuration.sql`
23. `20260101000023_staff_reservations.sql`

Activez Realtime Broadcast privé et configurez les règles d’authentification/e-mail dans le tableau de bord Supabase.
Pour l’espace client, activez également l’authentification par téléphone et configurez un fournisseur SMS. La caméra est utilisée uniquement pour scanner le QR d’un poste.
Pour inviter un employé, le propriétaire crée un code depuis Administration → Employés et le transmet directement à l’adresse e-mail prévue. L’employé crée son compte avec cette même adresse, confirme son e-mail puis saisit le code dans « Rejoindre une équipe ». L’application ne crée aucun compte employé sans invitation valide.
Les clients liés à une salle peuvent consulter ses produits disponibles et choisir entre les ajouter à une session active ou passer une commande indépendante. Une commande indépendante reste en attente jusqu’à ce qu’un employé confirme au comptoir la réception du paiement en espèces ou par carte; cette confirmation crée atomiquement la commande payée, le paiement, la facture et le mouvement de stock. Aucun paiement bancaire en ligne n’est intégré.
Une commande indépendante déjà payée peut être associée explicitement par le client à sa session active ou en pause. Cette association ne modifie pas la facture de la session et ne crée aucun débit supplémentaire; son chiffre d’affaires reste comptabilisé une seule fois à la date de vente d’origine.
Les clients et les membres du personnel peuvent consulter les 100 dernières factures auxquelles leur rôle leur donne accès; les nouvelles factures client sont diffusées via Realtime.
Les responsables du catalogue peuvent choisir des images JPG, PNG ou WebP (5 Mo maximum) pour les jeux et produits. Elles sont téléversées dans le bucket public `venue-catalog-images`; n’y placez aucune donnée privée.
Les postes peuvent être associés aux jeux compatibles depuis **Postes → Modifier**. Un tarif facultatif peut être défini pour chaque couple poste/jeu; sans tarif spécifique, le tarif du catalogue s’applique. Un poste sans association explicite accepte tous les jeux du catalogue. Le tarif est appliqué par les opérations de session serveur et enregistré dans les lignes de facturation; les sessions et transferts sont contrôlés côté PostgreSQL pour refuser un jeu non compatible.
La recherche globale est accessible depuis la navigation et couvre les jeux, produits, postes, clients, comptes de crédit autorisés, sessions par numéro, factures par numéro et commandes par identifiant, dans les limites des règles RLS du compte.
Les opérations RPC idempotentes qui acceptent `p_op` sont conservées dans une file locale chiffrée et renvoyées dans l’ordre avec le même identifiant après le rétablissement du réseau, uniquement pour le compte qui les a créées. Consultez **Synchronisation** dans la bannière d’état pour suivre les opérations en attente; une opération refusée par le serveur bloque les suivantes jusqu’à sa vérification et son traitement.
Cette file ne rend pas toutes les écritures disponibles hors ligne : les modifications directes du catalogue, des employés, des paramètres et les RPC sans `p_op` exigent une connexion. Un indicateur de réseau ne garantit pas l’accès à Supabase; aucune écriture n’est confirmée avant la réponse du serveur. En cas de résultat réseau incertain, ne créez pas manuellement une nouvelle opération.
Le propriétaire peut consulter les 100 dernières opérations du journal d’activité depuis Administration → Journal d’activité.
Les clients associés à une salle peuvent réserver un poste jusqu’à 30 jours à l’avance. Le propriétaire et le gérant peuvent également créer une réservation pour un client existant ou ajouter un client sans compte depuis **Réservations**. Les créneaux qui se chevauchent sont protégés par une contrainte PostgreSQL, même lorsque deux clients réservent au même instant.
Le propriétaire ou le gérant peut enregistrer des dépenses catégorisées; chaque opération est historisée et ajoutée au journal d’activité.
L’équipe peut ouvrir et clôturer des services de caisse. Les paiements espèces et dépenses créés pendant un service ouvert sont inscrits automatiquement dans son journal, puis comparés au montant compté à la clôture.
Les comptes clients disposent d’un portefeuille prépayé et d’un crédit plafonné. Les mouvements sont append-only; les rechargements et remboursements enregistrés en espèces sont ajoutés à la caisse ouverte, tandis que les règlements de session peuvent combiner espèces, carte, portefeuille et crédit. Le crédit est soumis à la limite du client et à la permission `manage_credit`.
Les notifications sont conservées et synchronisées en temps réel. Le propriétaire peut modifier le nom et le fuseau horaire de la salle; les clients voient les derniers mouvements de portefeuille et de crédit. Les horodatages sont conservés en UTC et affichés selon le fuseau configuré de la salle, y compris pour les périodes de rapports, les réservations et les promotions. Les promotions à durée limitée se gèrent depuis Administration → Promotions et un membre autorisé peut appliquer une réduction unique au total de jeu d’une session terminée avant son encaissement.
Les clients gagnent un point par tranche complète de 100 DA sur les factures associées à leur compte. Les points n’ont aucune valeur monétaire; ils servent uniquement à demander des récompenses définies par la salle. La demande réserve les points et le stock jusqu’à validation ou refus par l’équipe; un refus recrédite automatiquement les points.
Les adhésions sont activées manuellement par un propriétaire ou un gérant pour une durée définie; leurs avantages sont affichés comme texte, sans facturation récurrente ni modification automatique des prix. Les formules prépayées contiennent des minutes de jeu et au moins un produit choisi par la salle. Leur vente en espèces ou par carte enregistre une commande, un paiement et une facture, déduit immédiatement les produits du stock, et crédite les minutes au compte client. Les minutes et produits inclus expirent 30 jours après la vente. Le client peut utiliser ses minutes dans une session active compatible; l’équipe confirme la remise des produits inclus depuis Adhésions & formules.

## Installation Supabase

1. Créez un projet dans le tableau de bord Supabase et choisissez une région proche de vos clients.
2. Ouvrez **SQL Editor → New query**.
3. Ouvrez les fichiers `20260101000001_foundation.sql` à `20260101000023_staff_reservations.sql` dans l’ordre indiqué ci-dessus. Copiez le contenu d’un seul fichier dans une requête SQL et cliquez **Run**; attendez la réussite avant de passer au suivant. Appliquez et validez la migration 13 avant la 14, car celle-ci utilise les valeurs d’énumération ajoutées par la précédente. N’exécutez pas les fichiers `(... Copy).sql` ou `schema.sql`, qui sont des copies de référence et ne font pas partie de la séquence.
4. Dans **Authentication → Providers**, activez Phone et configurez un fournisseur SMS pour le parcours OTP client. Configurez aussi la confirmation des adresses e-mail pour l’inscription et les invitations des employés. Personnalisez les URL de redirection d’authentification pour vos domaines de production.
5. Dans **Authentication → Rate Limits**, vérifiez les limites OTP après avoir configuré le fournisseur SMS; des limites trop basses peuvent bloquer les codes de test.
6. Dans **Project Settings → API**, récupérez le Project URL et la clé publique `publishable` (ou l’ancienne clé `anon`). Fournissez-les au lancement avec `--dart-define` comme indiqué dans « Démarrage ». N’utilisez jamais `service_role` dans le client.
7. Vérifiez que le compte propriétaire peut s’inscrire et créer la salle, puis créez les postes et jeux avant les premiers essais de sessions. Pour le parcours employé, transmettez le code créé par le propriétaire à une adresse e-mail confirmée.
8. Testez d’abord dans un projet de développement. Le SQL Editor exécute chaque migration en tant qu’administrateur; gardez une copie de sauvegarde et ne relancez pas une migration déjà appliquée.

## Vérification

```sh
flutter analyze
flutter test
```
