# EduTrack

Application Flutter de suivi des cours et des présences.

## Configuration Firebase

Le projet contient déjà une configuration FlutterFire et Firebase Android.
Dans la console Firebase, activez **Authentication > Email/Password** et
créez la base Cloud Firestore avant de lancer les parcours connectés.
Si les plateformes Firebase changent, régénérez les fichiers avec :

```powershell
dart pub global activate flutterfire_cli
flutterfire configure
```

Les inscriptions publiques créent uniquement des comptes Étudiant. Pour
autoriser la gestion des rôles, attribuez le custom claim `admin: true` au
compte administrateur depuis un environnement de confiance utilisant le SDK
Firebase Admin, puis créez/ajustez son document `users/{uid}` avec le rôle
`admin`. N’attribuez jamais ce claim depuis l’application cliente. Les comptes
Enseignant et Administrateur sont provisionnés manuellement dans un environnement
de confiance : créer le compte Firebase Authentication, puis `users/{uid}` avec
le même UID, l’adresse e-mail, le nom et le rôle. Pour un administrateur,
attribuez aussi le custom claim `admin: true` avec Firebase Admin SDK. Le rôle
`admin` du document Firestore seul ne donne aucun droit administrateur.
L’application ne crée pas de comptes enseignant/admin et ne permet pas de
modifier les rôles depuis son interface.

Pour lancer l’application après la configuration :

```powershell
flutter run
```

## Module Étudiant — contrat Firestore

Les écrans Étudiant utilisent les collections et champs suivants. Les cours,
inscriptions, séances et notifications doivent être créés par les modules
Enseignant/Administrateur ou par un service de confiance. L’UID Firebase est
la clé d’identité de l’étudiant.

- `users/{uid}` : `uid`, `email`, `displayName`, `role`; `className` facultatif,
  modifiable uniquement par l’administration.
- `enrollments/{uid_courseId}` : `studentUid`, `courseId`, `status: active`.
  Le document ID déterministe permet aux règles de prouver l’inscription lors
  des lectures de cours et séances.
- `courses/{courseId}` : `name`, `teacherName`, `teacherUid`, `description`
  facultatif.
- `sessions/{sessionId}` : `courseId`, `teacherUid`, `startsAt` (Timestamp),
  `endsAt` (Timestamp facultatif), `room` facultatif.
- `attendance/{uid_sessionId}` : `studentUid`, `sessionId`, `courseId`,
  `status` (`present`, `late` ou `absent`), `recordedAt` (Timestamp serveur).
  Les écritures client sont interdites; les absences doivent être produites par
  le serveur ou l’appel enseignant prévu à cet effet.
- `users/{uid}/notifications/{notificationId}` : `title`, `message`,
  `createdAt` (Timestamp), `isRead` (bool). L’étudiant peut uniquement marquer
  sa notification comme lue.

Les règles de `firestore.rules` autorisent les lectures d’un cours/séance à son
enseignant, à l’administration ou à un étudiant dont l’inscription existe.
Avant le travail des autres membres, ils doivent produire des documents
conformes à ces champs et conventions de document ID. Déployez les règles après
validation commune :

```powershell
firebase deploy --only firestore:rules
```

### Pointage QR sur Firebase Spark

Le parcours QR et les actions serveur de l’application passent par `backend/`,
une API Express sur Node.js 22 avec Firebase Admin SDK. Aucune Cloud Function ni
Secret Manager n’est nécessaire. Les sources `functions/` restantes sont
historiques et ne sont plus appelées par Flutter. Le QR signé HMAC-SHA256 est
retourné en mémoire : ni le QR ni son jeton ne sont écrits dans Firestore. Le
backend vérifie le Firebase ID Token, le rôle et l’affectation enseignant,
l’inscription active, l’état/expiration de séance et le doublon dans une
transaction Firestore. Le serveur fixe l’heure de démarrage et l’expiration à
15 minutes; l’heure du téléphone n’est jamais utilisée pour valider un scan.

#### Démarrage local et tests

Installez Node.js 22 et Firebase CLI. Créez un compte de service Firebase dédié
avec uniquement les permissions Firestore (`roles/datastore.user`) et
Authentication Admin (`roles/firebaseauth.admin`). Conservez son JSON hors du
dépôt. L’API vérifie aussi le custom claim `admin: true` pour les comptes Admin.

Dans PowerShell, depuis le dépôt :

```powershell
cd backend
npm ci
npm test
$env:FIREBASE_PROJECT_ID = "edutrack-84667"
$env:FIREBASE_SERVICE_ACCOUNT_JSON = Get-Content "$env:USERPROFILE\edutrack-api-service-account.json" -Raw
$env:EDUTRACK_QR_SIGNING_SECRET = node -e "process.stdout.write(require('node:crypto').randomBytes(48).toString('base64url'))"
$env:CORS_ALLOWED_ORIGINS = "http://localhost:8080,http://127.0.0.1:8080,http://localhost:8081,http://127.0.0.1:8081"
npm start
```

Le secret généré ci-dessus est uniquement local. En production, générez une
nouvelle valeur aléatoire et stockez-la dans le gestionnaire de secrets de
l’hébergeur, jamais dans Flutter, Firestore, un fichier suivi par Git ou une
commande enregistrée dans l’historique. `FIREBASE_SERVICE_ACCOUNT_JSON` doit
également être une variable secrète de l’hébergeur (ou utilisez son identité
de service/ADC). Ne donnez pas de permissions de propriétaire au compte de
service.

Dans un autre terminal, configurez l’URL de l’API Flutter :

```powershell
cd ..
flutter pub get
flutter run -d chrome --web-port 8080 --dart-define=EDUTRACK_API_BASE_URL=http://127.0.0.1:3000
```

Le bouton « Créer et démarrer + QR » démarre immédiatement côté serveur.
« Planifier » conserve la création d’une séance future sans ouvrir sa fenêtre QR.

`npm test` utilise un Firebase Auth/Firestore en mémoire et vérifie les cas
autorisés et refusés sans modifier le projet Firebase. Pour valider les règles
localement avec l’émulateur Firestore :

```powershell
npm ci --prefix functions
firebase emulators:exec --only firestore "npm run test:rules --prefix functions"
```

#### Déploiement externe et tests appareil

Déployez `backend/` sur un hébergeur Node/Docker acceptant HTTPS, variables
d’environnement secrètes et une identité Firebase Admin. Par exemple, créez
un Web Service sur Render avec `backend/` comme répertoire racine, `npm ci`
comme commande d’installation et `npm start` comme commande de démarrage (ou
utilisez le Dockerfile). Configurez `FIREBASE_PROJECT_ID`,
`FIREBASE_SERVICE_ACCOUNT_JSON` (sauf si l’hébergeur fournit ADC),
`EDUTRACK_QR_SIGNING_SECRET` et `CORS_ALLOWED_ORIGINS` avec l’origine exacte de
votre application web. Utilisez l’URL HTTPS fournie par l’hébergeur :

```powershell
$apiUrl = "https://VOTRE-URL-API"
flutter run -d chrome --dart-define=EDUTRACK_API_BASE_URL=$apiUrl
flutter devices
flutter run -d "IDENTIFIANT-ANDROID" --dart-define=EDUTRACK_API_BASE_URL=$apiUrl
```

Sur téléphone physique, une API locale sur `localhost` désigne le téléphone :
utilisez l’URL HTTPS déployée. Autorisez l’accès caméra dans Chrome et
connectez-vous avec un compte enseignant affecté pour démarrer la séance, puis
avec un étudiant inscrit pour scanner. L’API répond également sur
`/health`; les résultats visibles localement ne prouvent pas le déploiement
externe.

Pour les tests locaux sur le même réseau Wi-Fi, démarrez l’API et Flutter Web
sur le PC, puis servez l’application Web sur l’interface réseau du PC. Le client
Web déduit alors l’API à partir de l’hôte de la page (`port 3000`), tandis que
l’API autorise en développement uniquement les origines HTTP locales sur les
ports Web `8080` et `8081`. Pour l’application Android native, fournissez
l’adresse IPv4 actuelle du PC au moment de la compilation :

```powershell
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.InterfaceAlias -eq "Wi-Fi" -and $_.AddressState -eq "Preferred" } |
  Select-Object -First 1 -ExpandProperty IPAddress)
flutter build apk --debug --dart-define=EDUTRACK_API_BASE_URL="http://$($lanIp):3000"
```

Le téléphone et le PC doivent rester sur le même Wi-Fi, et le PC doit rester
allumé avec les deux services actifs. Si l’adresse du PC change, reconstruisez
l’APK Android. N’utilisez pas cette configuration HTTP en production.

Les services externes peuvent exiger un forfait payant; disponibilité, prix,
quotas, mise en veille, temps de démarrage et conditions d’offre gratuite
varient selon le fournisseur et peuvent changer. Le forfait Firebase Spark
reste inchangé, mais les quotas Firestore/Auth s’appliquent toujours et
l’hébergement de l’API peut engendrer des coûts. Aucun backend n’est déployé
par cette branche. **Le parcours n’est pas opérationnel en production avant
déploiement HTTPS, configuration des secrets/permissions et essai réel avec
des comptes de test.**

Le dashboard, les cours, les séances et l’historique affichent des états de
chargement, erreur et données vides; ils ne génèrent pas de données de
démonstration. Les statistiques dépendent d’enregistrements `attendance`
complets, y compris les absences.

## Module Administrateur — extensions Firestore locales

Le module Admin ajoute les collections suivantes sans renommer ni migrer les
collections Student/Teacher existantes :

- `classes/{classId}` : `name`, `group`, `level`, `academicYear` (tous requis).
- `subjects/{subjectId}` : `name`, `classIds` (liste d’identifiants de classes),
  `description` facultatif.
- `teacherAssignments/{assignmentId}` : `teacherId`, `classId`, `subject`
  (ID de `subjects`) et `status` (`active` ou `inactive`). Une affectation
  active exige une matière associée à cette classe et un compte Teacher actif.
- `enrollments/{studentUid_courseId}` conserve `studentUid`, `courseId` et
  `status`; `classId` est facultatif et, lorsqu’il est présent, doit référencer
  la classe de l’affectation active dont l’ID est égal à `courseId`.
- `users/{uid}.isActive` est facultatif et vaut `true` par défaut pour les
  profils existants. Seul le serveur de confiance peut le modifier.

Pour que les affectations actives restent visibles par le Teacher actuel,
l’Admin crée également un document opérationnel `courses/{assignmentId}` avec
les champs existants `name`, `teacherName`, `teacherUid` et `description`.
L’ID commun sert de lien entre l’affectation et le cours consommé par Student,
Teacher, les inscriptions et les séances. Ce document est une projection de
compatibilité ; la relation classe/matière et son état restent dans
`teacherAssignments`.

Les notifications Admin sont écrites dans les sous-collections existantes
`users/{uid}/notifications` avec les champs déjà lus par Student : `title`,
`message`, `createdAt` (horodatage serveur) et `isRead: false`. Elles utilisent
Firestore uniquement ; aucun service FCM n’est ajouté dans ce changement.
À la clôture d’une séance, le serveur crée aussi une alerte destinée à
l’enseignant lorsqu’un étudiant cumule au moins deux absences enregistrées dans
ce cours. Les absences et leurs notifications sont créées de manière idempotente;
la clôture bloque d’abord les scans QR afin de préserver les présences validées.

Les profils Student/Teacher restent provisionnés selon les parcours actuels.
L’API externe `POST /api/admin/users/{uid}/status` peut activer ou désactiver un
profil Student ou Teacher existant ; elle ne crée aucun compte. La
désactivation écrit d’abord `isActive: false`, puis désactive le compte Firebase
Authentication. Les règles Firestore et l’API vérifient ce champ pour bloquer
aussi les sessions déjà connectées.

Le schéma `sessions` reste inchangé dans cette intégration. Les écrans Admin
classent les séances par date (`planifiée`, `en cours`, `terminée`), mais ne
stockent pas d’état d’annulation ni de demande d’autorisation. Ces champs
attendent le contrat convenu avec l’équipe Teacher. Les protections QR
(signature, fenêtre temporelle, inscription active et écriture serveur des
présences) restent en vigueur.

Les modifications des règles et de l’API sont locales et doivent être revues
avant tout déploiement. N’exécutez pas `firebase deploy --only functions` sur
Spark; aucun déploiement Firebase ou hébergeur n’est effectué par cette branche.
