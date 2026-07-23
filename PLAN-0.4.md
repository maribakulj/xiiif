# xiiif 0.4 — Plan d'exécution étape par étape

> **Document de travail de session** (à supprimer ou archiver avant le merge final).
> Source : `SPECS-0.4.md` (committé à côté, autonome). Ce plan découpe les specs en
> **16 étapes séquentielles** ; chaque étape est dimensionnée pour un seul tour de
> travail. L'utilisateur dit « continue » → on exécute la prochaine étape non cochée.
>
> Rédigé en français ; **le code, les docstrings, le README, le CHANGELOG et les
> messages de commit restent en anglais.**

---

## Protocole (à respecter à chaque étape)

1. Lire l'étape ci-dessous **et** les sections de `SPECS-0.4.md` qu'elle référence.
2. Implémenter, avec tests ERT hors-réseau (fixtures `examples/`, transports factices).
3. `make test` **et** `make compile-strict` verts avant de committer.
4. Commits atomiques (un par sujet), messages `feat:` / `fix:` / `docs:` en anglais.
5. Cocher la case de l'étape dans ce fichier, committer le plan mis à jour.
6. `git push -u origin claude/plan-complet-etapes-xvr4d7` (retry backoff si réseau).
7. Terminer par un court compte-rendu en français + annonce de l'étape suivante.

### Reprise dans une session neuve (conteneur vierge)

- Emacs absent du conteneur : `sudo apt-get update -q; sudo apt-get install -y -q emacs-nox`
  (l'update peut afficher des erreurs de PPA non signés — ignorables tant que
  l'install aboutit ; vérifié : Emacs 29.3 s'installe et la suite passe).
- `git checkout claude/plan-complet-etapes-xvr4d7 && git pull origin claude/plan-complet-etapes-xvr4d7`
- Lire `SPECS-0.4.md` puis ce fichier ; reprendre à la première étape non cochée.

### État de la base (mesuré au départ, HEAD = d1133a7)

- `make test` : **185/185 verts** (Emacs 29.3).
- `make compile-strict` : **rouge sur checkout propre** — `xiiif-ui.el:310` référence
  `#'xiiif-download-image` (défini dans `xiiif.el:253`) sans `declare-function`.
  Défaut préexistant, corrigé à l'étape 1.

---

## État d'avancement

- [x] Étape 0 — Environnement, ligne de base, plan (cette session)
- [x] Étape 1 — Bugs E1–E3 + compile-strict propre
- [ ] Étape 2 — JSON natif (A4) + garde de taille (E6)
- [ ] Étape 3 — Backend HTTP commutable url/plz (A1)
- [ ] Étape 4 — Ordonnanceur `xiiif-fetch.el` (A2)
- [ ] Étape 5 — Caches : éviction HTTP (E7) + cache disque d'images (A3)
- [ ] Étape 6 — Migration interne vers `xiiif-fetch`
- [ ] Étape 7 — Régions parsées partout (C1, corrige M1)
- [ ] Étape 8 — Ancre canonique + Content State + Mirador précis (C2, corrige M7)
- [ ] Étape 9 — Viewer : modèle & géométrie (B1, corrige M6)
- [ ] Étape 10 — Viewer : rendu & navigation (B2)
- [ ] Étape 11 — Viewer : commandes & intégration (B3)
- [ ] Étape 12 — Notes ancrées, backend org (C3)
- [ ] Étape 13 — Surface batch (D)
- [ ] Étape 14 — Housekeeping (E4, E5, E8)
- [ ] Étape 15 — Pagination (E9) + option ALTO boxes (E10)
- [ ] Étape 16 — Release 0.4.0 : docs, CHANGELOG, bump

---

## Sprint 1 — Fondations

### Étape 1 — Bugs E1–E3 + compile-strict propre

Specs : §1.2 (B1, B2, B3), §6 (1–3).

- **B1** `xiiif-annotations-collect` (`xiiif-annotations.el:103-140`) : refactor en
  deux phases — collecter les thunks de fetch, puis les dispatcher ; le contrôle de
  complétion ne court plus pendant la boucle d'émission. Le contrat « CALLBACK is
  invoked exactly once » tient même quand `xiiif-api-fetch-json-async` invoque
  l'errback *synchronement* (URL invalide, `xiiif-api.el:237-240`).
  Test de régression : errback synchrone au milieu d'une liste de pages.
- **B2** course de la vignette (`xiiif-ui.el:339-361, 403`) : handle buffer-local
  annulé à chaque re-rendu **ou** compteur de génération vérifié dans le callback ;
  plus d'insertion à `point-min` après `erase-buffer`.
  Test : deux rendus rapprochés, le callback du premier fetch ne doit rien insérer.
- **B3** `g` dans le buffer annotations (`xiiif-ui.el:770`, `xiiif.el:484-503`) :
  commande de refresh dédiée sur le modèle de `xiiif-ui--ocr-refresh`, branchée dans
  `xiiif--refresh-source`. Test : le refresh relance `xiiif-show-annotations`.
- **Base compile-strict** : `declare-function xiiif-download-image` (et toute autre
  occurrence du même défaut) dans `xiiif-ui.el` pour que `make compile-strict`
  passe sur checkout propre (Emacs 29.3).

Commits : un `fix:` par bug + un pour la déclaration compile-strict.

### Étape 2 — JSON natif (A4) + garde de taille (E6)

Specs : §2 A4, §2 A1 (garde), §6 (6).

- `xiiif-api--parse-json` (`xiiif-api.el:67-78`) : `json-parse-string` si
  `(fboundp 'json-parse-string)` avec `:object-type 'alist :array-type 'array
  :null-object nil :false-object :json-false` ; fallback `json-read-from-string`.
  Test d'équivalence natif vs pur-Elisp sur **tous** les `examples/*.json`.
- `defcustom xiiif-api-max-body-size` (défaut ~50 Mo) : refuser un corps annoncé
  au-delà via `Content-Length` avec une erreur `xiiif-http-error` dédiée
  (nouvelle sous-erreur dans `xiiif-errors.el`). Test avec transport factice.

Commits : `feat: use native json-parse-string when available`,
`feat: add response body size guard`.

### Étape 3 — Backend HTTP commutable url/plz (A1)

Specs : §2 A1.

- Abstraction interne de transport dans `xiiif-api.el` (dispatch par fonction,
  pas de changement du protocole public : mêmes fonctions, mêmes errbacks
  `(SYMBOL URL &rest DATA)`, mêmes handles annulables).
- Backend `url` : l'existant, extrait derrière l'abstraction.
- Backend `plz` : chargé par `(require 'plz nil t)` — **strictement optionnel**,
  aucune dépendance dure. Handle annulable = process retourné par plz.
  Streaming vers fichier pour les téléchargements (pas de buffer Elisp intermédiaire).
- `defcustom xiiif-api-backend` : `auto` (plz si présent) / `url` / `plz`.
- En-têtes (profils, auth, validateurs conditionnels ETag) passés identiquement
  aux deux backends.
- Tests : sélection de backend (avec et sans feature `plz` simulée), équivalence
  de comportement via transport factice ; toute la suite existante inchangée.

Commit : `feat: pluggable HTTP transport with optional plz backend`.

---

## Sprint 2 — Ordonnanceur + caches

### Étape 4 — Ordonnanceur `xiiif-fetch.el` (A2)

Specs : §2 A2. Nouveau module ~150-200 lignes, indépendant du backend.

- File + plafond `xiiif-fetch-max-concurrent` (défaut 4).
- Politesse par hôte `xiiif-fetch-host-interval` (défaut 0.15 s) ; clé
  `:min-interval` dans `xiiif-server-profiles`.
- 429/503 + `Retry-After` : parser l'en-tête (secondes et date HTTP), suspendre la
  file de l'hôte, backoff exponentiel par défaut, rejouer ; après N tentatives,
  échouer avec l'erreur d'origine.
- Déduplication : même URL en vol → un fetch, N callbacks.
- Priorités : `:priority 'interactive` (défaut) > `'prefetch`.
- Annulation groupée : `:group`, `xiiif-fetch-cancel-group`.
- API : `xiiif-fetch-json`, `xiiif-fetch-bytes`, `xiiif-fetch-file` (async, mêmes
  conventions d'errback). Exposer un compteur/inspecteur simple (utile aux
  critères B : « aucune requête doublonnée »).
- Tests **sans réseau** (transport factice injecté) : plafond, intervalle par hôte,
  dédup, priorités, annulation de groupe, `Retry-After` honoré.

Commit : `feat: add xiiif-fetch request scheduler`.

### Étape 5 — Caches : éviction HTTP + cache disque d'images (A3)

Specs : §2 A3, §6 (7).

- Éviction du cache HTTP (`xiiif-http-cache.el`) : `xiiif-http-cache-max-entries`
  (défaut 512) et/ou `-max-bytes` ; purge LRU par `:stored` au moment du store.
- Cache disque d'images (nouveau, même répertoire parent que le cache existant) :
  clé = URL, valeur = octets bruts ; plafond en octets (défaut ~200 Mo), LRU.
  Branché sur `xiiif-fetch-bytes` via `:cache t`. Prérequis du viewer
  (revisiter une page = zéro réseau).
- Tests : éviction LRU (entries et bytes), hit/miss disque, plafond respecté.

Commits : `feat: add LRU eviction to HTTP cache`, `feat: add on-disk image byte cache`.

### Étape 6 — Migration interne vers `xiiif-fetch`

Specs : §2 A2 (dernier point).

- Migrer les appels internes interactifs (UI vignettes, annotations, search, OCR,
  collections…) de `xiiif-api-*-async` vers `xiiif-fetch-*` ; `xiiif-api-*` reste
  la couche transport. Conserver l'annulation par buffer (`xiiif--inflight`) en la
  faisant coopérer avec les groupes (ou la remplacer par un groupe par buffer).
- Comportement visible strictement identique ; adapter les tests existants
  (refresh, inflight) sans en affaiblir les assertions.
- `M-x xiiif-open-manifest` sur un gros manifest reste fluide (critère A).

Commit : `refactor: route interactive fetches through xiiif-fetch`.

---

## Sprint 3 — Ancres (données)

### Étape 7 — Régions parsées partout (C1, corrige M1)

Specs : §4 C1, §1.2 M1.

- Struct `xiiif-region` `(x y w h)` + parseurs :
  fragment Media Fragments `#xywh=` et `#xywh=percent:` sur cibles chaînes ;
  `SpecificResource` → `selector` → `FragmentSelector` (v3) ;
  `on`/`full`+`selector` (v2, hits de recherche).
- Nouveau slot `region` dans `xiiif-annotation` (`xiiif-annotations.el:55-63`)
  et `xiiif-search-hit` (`xiiif-search.el:74-80` — remplacer le
  `split-string on "#"` qui jette le fragment).
- UI : colonne/champ « Region » dans les buffers annotations et search.
  `RET` sur un hit/annotation avec région → pour l'instant canvas detail
  (le viewer branchera à l'étape 11).
- **Nouvelles fixtures** `examples/` : AnnotationPage avec `SpecificResource`,
  réponse Search v2 avec xywh (`on` + selector).
- Tests : parseurs (xywh, percent, v2, v3, cibles sans région), portage dans les
  structs, affichage.

Commit : `feat: parse and carry xywh regions in annotations and search hits`.

### Étape 8 — Ancre canonique + Content State + Mirador précis (C2, corrige M7)

Specs : §4 C2.

- Format d'ancre xiiif : alist sérialisable, stable, **versionnée** :
  `(:manifest URL :canvas ID :region (X Y W H) :label STR)` — région en pixels
  canvas pleine résolution, omissible.
- Export : `xiiif-content-state-url` — ancre → annotation IIIF **Content State
  1.0** → base64url du JSON → `<viewer>?iiif-content=<state>`.
  Attention à l'alphabet base64url **sans padding** (spéc Content State).
- `xiiif-open-in-mirador` (`xiiif.el:586-607`) : argument optionnel ancre →
  bascule précise canvas+région au lieu du manifest seul.
- Import : `xiiif-content-state-parse` (URL complète ou base64 nu) → ancre →
  saut vers canvas detail (le viewer prendra le relais à l'étape 11).
- Tests : round-trip ancre → Content State → parse → même ancre ; encodage/
  décodage base64url ; ancre sans région ; URL Mirador générée.

Commit : `feat: canonical anchors with IIIF Content State import/export`.

---

## Sprint 4 — Viewer

### Étape 9 — Viewer : modèle & géométrie (B1, corrige M6)

Specs : §3 B1, §1.2 M6. Nouveau module `xiiif-view.el` (partie données seulement).

- `cl-defstruct xiiif-view-state` : `manifest-url canvas-id x y w h level rotation`
  — coordonnées canoniques **en pixels pleine résolution du canvas**, jamais des
  pixels écran. Conversions state ↔ alist sérialisable (pour C et D).
- Échelle de zoom dérivée de `info.json` (`sizes`/`tiles`/compliance) ; défaut
  1/16, 1/8, 1/4, 1/2, 1 sinon.
- `xiiif-image-closest-size` (dans `xiiif-image.el`) : choisir la taille la plus
  proche parmi les `sizes`/`tiles` advertisées — jamais synthétiser une taille
  arbitraire sur un serveur level-0. **Rebrancher la vignette**
  (`xiiif-core.el:306-319`, `!200,200` codé en dur) dessus.
- Géométrie : state → (région Image API + taille demandée + `:scale` affichage),
  avec marge de préchargement et clamp aux bords du canvas.
- **Nouvelle fixture** : `examples/` `info.json` level-0 (compliance level0,
  `sizes` explicites, pas de `tiles` arbitraires).
- Tests : échelle dérivée d'un `info.json` fixture ; closest-size (level 0/1/2) ;
  géométrie état ↔ région requêtée ↔ affichage ; clamp aux bords ; HiDPI
  (facteur 2 simulé dans le calcul).

Commit : `feat: view state model, zoom scale and level-0 safe size selection`.

### Étape 10 — Viewer : rendu & navigation (B2)

Specs : §3 B2.

- Buffer `*XIIIF View*`, mode dérivé de `special-mode`, image unique centrée.
- Requête région = vue + marge (1 écran autour), taille = fenêtre × facteur HiDPI ;
  HiDPI via `(frame-scale-factor)` derrière `fboundp` (Emacs 29+ ; défaut 1),
  affichage avec `:scale (/ 1.0 facteur)`.
- Proxy immédiat : pendant pan/zoom, réafficher l'image en main redimensionnée
  (`:scale`) ; la version nette part via `xiiif-fetch` et remplace au retour ;
  coalescence par `run-with-idle-timer` (~0.15 s).
- Navigation : pan flèches/hjkl (pas = ½ écran, `C-u` = pas fin), zoom `+`/`-`/`0`,
  `g` recharge, `q` quitte. Chaque navigation annule le groupe de la vue
  précédente (`xiiif-fetch-cancel-group`) et met en file les préchargements des
  régions voisines en `:priority 'prefetch`.
- Mémoire : LRU local (~8 entrées) + `image-flush` à l'éviction.
- Terminal (`display-graphic-p` nil) : message clair + proposition d'ouvrir l'URL.
- Tests batch avec images fixtures locales (`file://`) : rendu, remplacement
  proxy→net, éviction LRU, annulation à la navigation, fallback terminal.

Commit : `feat: region viewer rendering and keyboard navigation`.

### Étape 11 — Viewer : commandes & intégration (B3)

Specs : §3 B3, fin de §4 C1/C2.

- `xiiif-view-canvas` (commande, depuis le canvas courant), `xiiif-view-region`
  (fonction, depuis un state/ancre — utilisée par C et D).
- `xiiif-view-copy-url` (URL Image API exacte de la vue),
  `xiiif-view-open-in-mirador` (via Content State, étape 8),
  `xiiif-view-annotate` (stub qui branchera sur C3 à l'étape 12).
- Touches : `v` dans le canvas detail et le canvas browser → viewer.
- `RET` sur hit de recherche / annotation **avec** région → viewer sur la région
  (remplace le dégradé de l'étape 7 ; garder le fallback canvas detail si
  affichage graphique impossible).
- `xiiif-content-state-parse` → saute désormais dans le viewer quand une région
  est présente.
- Tests : bindings, view-state construit depuis un hit/une ancre, URL copiée.

Commit : `feat: viewer commands and integration with search, annotations, anchors`.

---

## Sprint 5 — Écriture & batch

### Étape 12 — Notes ancrées, backend org (C3)

Specs : §4 C3.

- `xiiif-annot-create` (commande dans le viewer et le canvas detail) : construit
  l'ancre du contexte courant, demande titre/texte, délègue à
  `xiiif-annot-backend-function` (defcustom).
- Backend `org` par défaut (dans le paquet) : insertion/append dans un fichier Org
  configurable — lien manifest, drawer `:PROPERTIES:` (`:XIIIF_MANIFEST:`,
  `:XIIIF_CANVAS:`, `:XIIIF_REGION:`), lien Content State, lien Image API de la
  région. Org chargé paresseusement comme aujourd'hui.
- Enrichir `xiiif-org-metadata-block` (`xiiif-org.el`) : canvas-id + region +
  content-state (aujourd'hui s'arrête au canvas).
- `xiiif-annot-visit` : depuis une entrée Org au point, relire l'ancre et rouvrir
  exactement la vue (viewer si région, canvas detail sinon).
- Tests : entrée org produite relisable, round-trip create → visit, backend
  personnalisé injecté.

Commit : `feat: anchored note creation with pluggable org backend`.

### Étape 13 — Surface batch (D)

Specs : §5.

- `xiiif-batch-open (url)` → charge (sync) + rend le manifest, retourne un résumé
  sérialisable (titre, nb canvases, structures présentes/absentes).
- `xiiif-batch-goto (anchor)` → viewer/canvas sur l'ancre ; accepte l'alist ancre
  **ou** une URL Content State.
- `xiiif-batch-current-view ()` → ancre de la vue courante, nil sinon.
- `xiiif-batch-annotate (anchor title body)` → C3 sans prompts.
- Garanties : aucun `read-string`/prompt dans ces chemins ; erreurs signalées
  (pas de `user-error` muets) ; docstrings avec exemples
  `emacsclient -e '(xiiif-batch-goto ...)'`.
- Test ERT batch dédié : dans `emacs -Q --batch`, charger un manifest fixture,
  produire une ancre, la convertir en Content State, créer une note org — sans
  aucune interaction (critère D).

Commit : `feat: batch scripting surface (open, goto, current-view, annotate)`.

### Étape 14 — Housekeeping (E4, E5, E8)

Specs : §6 (4, 5, 8), §1.2 D1–D3.

- **D1** : ré-appliquer les marques du canvas browser après refresh, par
  canvas-id (`tabulated-list-print t`, `xiiif-ui.el:197`). Test.
- **D2** : défaut de `xiiif-preferred-languages` (`xiiif-core.el:24`) dérivé de la
  locale — préfixer la langue de `current-language-environment` à
  `("en" "none" "und")`. Test avec environnement de langue simulé.
- **D3** : intro `ROADMAP.md` (mentionne encore 0.1.0) mise à jour ; typo Homepage
  `maribakulj/maribakulj/xiiif` dans `xiiif-upgrade.el:6`.

Commits : `fix:` par sujet.

### Étape 15 — Pagination (E9) + option ALTO boxes (E10)

Specs : §6 (9, 10), §1.2 D4/D5. Peut glisser en 0.5 : si trop lourd, ne faire que
la partie simple et **documenter la limite** dans README/ROADMAP.

- **E9** : suivre `next` dans les réponses Search API et les
  AnnotationCollection (borne de sécurité sur le nombre de pages ; annulable).
  Tests avec fixtures multi-pages.
- **E10 (optionnel)** : `xiiif-ocr-alto-boxes` — parser HPOS/VPOS/WIDTH/HEIGHT
  (`xiiif-ocr.el:107-125`) → liste de `(STRING . REGION)`. Ne pas changer
  l'extraction texte existante.

Commits : `feat: follow Search and AnnotationCollection pagination`,
(`feat: extract ALTO word boxes` si fait).

### Étape 16 — Release 0.4.0

Specs : §7 sprint 5 (fin), contraintes §7.

- README (anglais) : sections **Viewer**, **Anchors**, **Scripting** (exemples
  `emacsclient`), mise à jour des tables de commandes/keybindings.
- CHANGELOG (Keep a Changelog) : tout 0.4.0 ; bump `Version:` dans les en-têtes.
- Vérifier `Package-Requires` inchangé (Emacs 27.1+) ; toutes les facilités 29+
  derrière `fboundp` ; `plz` nulle part en dépendance dure.
- Relecture finale : conventions `xiiif-`/`xiiif--`, docstrings impératives,
  hors-périmètre respecté (§7 : pas de deep-zoom continu, pas d'écriture
  d'annotations distantes, pas de SQLite).
- Dernier passage `make test` + `make compile-strict` ; retirer `PLAN-0.4.md` et
  `SPECS-0.4.md` du dépôt dans le commit final (ou les garder si l'utilisateur
  préfère — demander à ce moment-là).
- Push final. PR seulement si l'utilisateur la demande.

Commits : `docs: document viewer, anchors and scripting`, `chore: release 0.4.0`.

---

## Garde-fous permanents (rappel des specs §7)

- Emacs 27.1+ ; facilités 29+ toujours derrière `fboundp`.
- Zéro dépendance obligatoire ; `plz` et Org strictement optionnels/paresseux.
- Tests sans réseau uniquement (fixtures + transports factices).
- `make test` et `make compile-strict` verts à chaque étape ; CI inchangée.
- Text-first : le viewer est une console, pas un Mirador. En cas d'arbitrage,
  simplicité + bascule web plutôt que performance héroïque.
- Ne pas rediscuter les décisions d'architecture actées (§0 des specs).
