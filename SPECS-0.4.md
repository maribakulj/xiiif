# xiiif 0.4 — Revue de code & spécifications

> **Document d'entrée pour une nouvelle session de travail sur `maribakulj/xiiif`.**
> Il est autonome : tout le contexte nécessaire est inclus. Rédigé en français ;
> le code, les docstrings, le README et le CHANGELOG du dépôt restent **en anglais**.
> Basé sur une revue complète du code à la révision `d1133a7` (v0.3.0, 16 modules,
> 22 suites ERT / 2 684 lignes de tests, CI GitHub Actions).

---

## 0. Contexte système — pourquoi ces specs

`xiiif` n'est pas un projet isolé. Il est la **console IIIF humaine** d'un système
plus large en trois couches :

1. **Moteur agentique** (fork OpenScience, hors Emacs) : un agent de recherche
   autonome (humanités numériques, ML/NLP, STEM) qui tourne des heures dans un
   démon local. L'agent **ne dépend jamais d'Emacs ni de xiiif** : ses « yeux »
   IIIF sont des outils MCP (serveur BnF/Gallica séparé) qui lui livrent des
   régions d'images directement dans son contexte.
2. **Console humaine** = `xiiif` dans Emacs : structure-first, clavier,
   scriptable. C'est ici que l'humain lit, vérifie, annote, relie à ses notes.
3. **Bascule graphique** : Mirador/OpenSeadragon dans le navigateur pour le
   deep-zoom fluide. `xiiif-open-in-mirador` existe déjà ; la bascule doit
   devenir *précise* (canvas + région, pas seulement le manifest).

Décisions d'architecture actées (à ne pas rediscuter dans la session) :

- **Pas de visionneuse deep-zoom continue dans Emacs.** Le moteur d'affichage
  d'Emacs (glyphes, redisplay mono-thread, pas de canvas GPU) rend le zoom
  continu 60 fps inatteignable ; ce n'est PAS l'objectif. L'objectif est un
  **viewer de région pas-à-pas soigné** (Spec B) : suffisant pour la lecture
  rapprochée et la supervision, avec bascule Mirador pour le reste.
- **Philosophie du paquet** : text-first, zéro dépendance obligatoire,
  dégradation propre, tout asynchrone côté interactif. À préserver.
- **Le lien avec les notes de l'utilisateur** (vault Org/Markdown partagé avec
  un agent et Obsidian) se fait par un **format d'ancre canonique** (Spec C) —
  la clé de voûte qui permet à l'agent, à Emacs et à Mirador de « regarder le
  même endroit ».
- **La surface de pilotage externe** (agent via `emacsclient --eval`, scripts)
  réutilise les variantes synchrones existantes et quelques fonctions batch
  propres (Spec D).

---

## 1. État des lieux (revue à `d1133a7`)

### 1.1 Qualités à préserver absolument

- **Taxonomie d'erreurs** propre (`xiiif-errors.el`) + protocole errback
  uniforme `(SYMBOL URL &rest DATA)` dans toute l'API.
- **Annulation** : handles retournés par les fetchs async, `xiiif-api-cancel`
  (`xiiif-api.el:273`), `xiiif--inflight` par buffer avec annulation au refresh.
- **Modèle de données** memoïsé (`canvas-cache`, index O(1)
  `xiiif-manifest-find-canvas`, `xiiif-core.el:499`).
- **Sécurité** : lecture d'historique whitelistée (`xiiif-cache.el:168-205`),
  auth via `auth-source` (`xiiif-profiles.el:77-108`), secrets hors init.
- **Cache HTTP conditionnel** ETag/304 (`xiiif-http-cache.el`).
- **Profils par serveur** (headers, overrides Image API) (`xiiif-profiles.el`).
- **Hooks** d'extension aux points de rendu (`xiiif.el:77-97`).
- **Discipline projet** : tests ERT hors-réseau avec fixtures (`examples/`),
  `make compile-strict` (warnings = erreurs), CHANGELOG Keep-a-Changelog,
  conventions de nommage (`xiiif-` public / `xiiif--` privé).
- **Variantes synchrones** (`xiiif-api-fetch-json`, `xiiif-ocr-fetch-sync`,
  `xiiif-image-download`, `xiiif-image-fetch-info`) : vérifié, **aucun chemin
  interactif ne les appelle** — elles sont l'API de scripting. Les garder ;
  Spec D les promeut en surface batch documentée.

### 1.2 Défauts constatés (avec références)

Bugs réels :

- **B1 — Double invocation du callback** dans `xiiif-annotations-collect`
  (`xiiif-annotations.el:103-140`). Si un errback est invoqué *synchronement*
  pendant la boucle d'émission (cas : URL invalide,
  `xiiif-api-fetch-json-async` appelle l'errback immédiatement,
  `xiiif-api.el:237-240`), `pending` peut retomber à 0 en cours de boucle →
  `finish` appelé une première fois, puis à nouveau à la fin des fetchs
  restants. Le contrat « CALLBACK is invoked exactly once » est violé.
- **B2 — Course du marqueur de vignette** (`xiiif-ui.el:339-361, 403`).
  Le fetch de vignette n'est pas annulé quand le buffer canvas est re-rendu ;
  après `erase-buffer` le marker retombe à `point-min` et l'image s'insère au
  mauvais endroit. Il faut un handle buffer-local annulé à chaque re-rendu
  (ou un compteur de génération vérifié dans le callback).
- **B3 — `g` incohérent dans le buffer annotations** (`xiiif-ui.el:770` +
  `xiiif.el:484-503`). `xiiif-annotations-mode` n'a pas de branche dans
  `xiiif--refresh-source` → `g` re-rend l'aperçu du manifest à la place des
  annotations. Faire comme l'OCR (`xiiif-ui--ocr-refresh`) : une commande de
  refresh dédiée qui relance `xiiif-show-annotations`.

Manques structurants :

- **M1 — Les régions `#xywh=` sont jetées.** Les cibles d'annotations
  (`xiiif-annotations.el:55-63`) et les hits de recherche
  (`xiiif-search.el:74-80`, `split-string on "#"`) perdent le fragment
  Media Fragments et les `SpecificResource`/`FragmentSelector`. C'est
  exactement l'information dont la Spec C a besoin — la parser et la porter
  dans les structs.
- **M2 — Aucun ordonnanceur réseau.** Async ≠ géré : pas de file, pas de
  plafond de concurrence, pas de politesse par hôte, pas de déduplication,
  pas de priorités, pas d'annulation groupée. Le 429 est *signalé*
  (`xiiif-api.el:202`) mais jamais *prévenu* ; `Retry-After` ignoré.
- **M3 — Moteur `url.el` uniquement** : TLS/redirections capricieux, pas de
  HTTP/2, corps entièrement bufferisés en mémoire Elisp (gênant pour les
  images ; aucune garde de taille dans `xiiif-api-fetch-bytes-async`,
  `xiiif-api.el:284-325`).
- **M4 — Caches incomplets** : le cache HTTP n'a **aucune éviction**
  (croissance illimitée, `xiiif-http-cache.el`) ; les **octets d'images ne
  sont jamais cachés sur disque** (prérequis du viewer).
- **M5 — Parseur JSON lent** : `json-read-from-string` pur Elisp
  (`xiiif-api.el:67-78`). Emacs 27.1+ (le minimum du paquet) fournit
  `json-parse-string` natif (~10× plus rapide sur les gros manifests
  Gallica).
- **M6 — Niveau 0 non défendu** : `xiiif-image-url` « trusts the caller »
  (`xiiif-image.el:14-16`) et la vignette synthétise `!200,200`
  (`xiiif-core.el:306-319`) qui renvoie 404 sur un serveur level-0. Les
  données pour bien faire existent déjà (`xiiif-image-info` : compliance,
  `sizes`, `tiles`) mais ne sont pas consultées.
- **M7 — Pas de IIIF Content State API** : la bascule Mirador est
  manifest-level seulement (`xiiif.el:586-607`) ; pas d'ancre partageable
  canvas+région.

Détails / housekeeping :

- **D1** : marques du canvas browser perdues au refresh
  (`tabulated-list-print t`, `xiiif-ui.el:197`) — les ré-appliquer par id.
- **D2** : `xiiif-preferred-languages` par défaut `("en" "none" "und")`
  (`xiiif-core.el:24`) — dériver un défaut de la locale (ajouter la langue de
  `current-language-environment` en tête) ; l'utilisateur principal est
  francophone.
- **D3** : intro de `ROADMAP.md` périmée (« version 0.1.0 ») ; typo Homepage
  `maribakulj/maribakulj/xiiif` (`xiiif-upgrade.el:6`).
- **D4** : pagination absente — Search API (`next`) et AnnotationCollection
  (TODO déjà listé dans la roadmap).
- **D5** : extraction ALTO regex-only, jette les boîtes de mots
  (HPOS/VPOS/WIDTH/HEIGHT, `xiiif-ocr.el:107-125`) — optionnel : un
  `xiiif-ocr-alto-boxes` pour superposer texte↔régions plus tard.
- **D6** : vignettes `create-image` sans contrainte de taille ni gestion
  HiDPI (`xiiif-ui.el:356`) — acceptable pour des vignettes, à faire
  proprement dans le viewer.

---

## 2. Spec A — Réseau v2 : moteur, ordonnanceur, caches

**Objectif.** Transformer « des requêtes async » en « un système de
chargement » : rapide, poli envers les serveurs (Gallica throttle), et prêt à
servir le viewer (Spec B). Aucune nouvelle dépendance obligatoire.

### A1. Backend HTTP commutable (`xiiif-api`)

- Introduire une abstraction interne de transport avec deux backends :
  - `url` : l'existant (fallback universel, zéro dépendance) ;
  - `plz` : via le paquet GNU ELPA `plz` (curl) **si disponible**
    (`(require 'plz nil t)`) — TLS/redirections robustes, HTTP/2 multiplexé,
    streaming vers fichier sans buffer Elisp intermédiaire.
- `defcustom xiiif-api-backend` : `auto` (plz si présent) / `url` / `plz`.
- Le protocole public ne change pas : mêmes fonctions, mêmes callbacks
  `(SYMBOL URL &rest DATA)`, mêmes handles annulables (pour plz : l'objet
  process retourné). Les en-têtes (profils, auth, validateurs conditionnels)
  passent identiquement.
- Garde de taille : refuser (erreur `xiiif-http-error` dédiée) un corps
  au-delà de `xiiif-api-max-body-size` (defcustom, défaut ~50 Mo) quand
  `Content-Length` l'annonce ; pour les téléchargements de fichiers, streamer
  vers disque (plz sait le faire ; url.el garde le comportement actuel).

### A2. Ordonnanceur (`xiiif-fetch.el`, nouveau module)

Petit (~150-200 lignes), indépendant du backend, file générique :

- **File + plafond** : `xiiif-fetch-max-concurrent` (défaut 4) requêtes en
  vol ; le reste attend.
- **Politesse par hôte** : `xiiif-fetch-host-interval` (défaut 0.15 s) entre
  deux départs vers un même hôte ; configurable par profil serveur
  (`xiiif-server-profiles`, nouvelle clé `:min-interval`).
- **429/503 + `Retry-After`** : parser l'en-tête, suspendre la file de l'hôte
  pendant la durée indiquée (défaut exponentiel sinon), rejouer la requête ;
  au-delà de N tentatives, échouer avec l'erreur d'origine.
- **Déduplication** : deux demandes du même URL en vol → un seul fetch, deux
  callbacks.
- **Priorités** : `:priority 'interactive` (défaut) > `'prefetch`. Les
  préchargements ne partent que si rien d'interactif n'attend.
- **Annulation groupée** : chaque demande accepte `:group SYMBOL/objet` ;
  `xiiif-fetch-cancel-group` annule tout un groupe (le viewer annulera le
  groupe de la vue précédente à chaque navigation).
- API : `xiiif-fetch-json`, `xiiif-fetch-bytes`, `xiiif-fetch-file`
  (async, mêmes conventions d'errback). Les appels internes du paquet
  migrent dessus ; `xiiif-api-*` reste la couche transport.

### A3. Caches

- **Éviction du cache HTTP** : `xiiif-http-cache-max-entries` (défaut 512)
  et/ou `-max-bytes` ; purge LRU par `:stored` au moment du store (amorti).
- **Cache disque d'images** (nouveau, même répertoire parent) : clé = URL,
  valeur = octets bruts ; plafond en octets (défaut ~200 Mo), LRU. Utilisé
  par `xiiif-fetch-bytes` quand `:cache t`. C'est le prérequis du viewer
  (revisiter une page = zéro réseau).

### A4. Parseur JSON natif

- Dans `xiiif-api--parse-json` : utiliser `json-parse-string` quand
  `(fboundp 'json-parse-string)` avec `:object-type 'alist :array-type
  'array :null-object nil :false-object :json-false` (shapes identiques aux
  actuelles : alist à clés symboles, vecteurs, `:json-false`) ; fallback
  `json-read-from-string` sinon. Vérifier par test d'équivalence sur les
  fixtures.

**Critères d'acceptation A.**
- `make test` et `make compile-strict` verts ; aucune dépendance dure ajoutée.
- Tests unitaires de l'ordonnanceur **sans réseau** (transport factice
  injecté) : plafond respecté, intervalle par hôte respecté, dédup, priorités,
  annulation de groupe, `Retry-After` honoré.
- Test d'équivalence json-parse vs json-read sur `examples/*.json`.
- Un `M-x xiiif-open-manifest` sur un gros manifest reste fluide et ne change
  aucun comportement visible (hors vitesse).

---

## 3. Spec B — `xiiif-view.el` : viewer de région pas-à-pas

**Objectif.** La seule brique visuelle manquante : afficher *une région d'un
canvas à un niveau de zoom* dans un buffer Emacs, navigation clavier,
réactivité soignée — **sans** prétendre au zoom continu. C'est une console de
lecture rapprochée et de supervision, avec bascule précise vers Mirador.

### B1. Modèle

- `cl-defstruct xiiif-view-state` : `manifest-url canvas-id x y w h level
  rotation` — coordonnées **canoniques en pixels pleine résolution du
  canvas** (jamais des pixels écran). `level` = index dans une échelle de
  zoom dérivée de `info.json` (`sizes`/`tiles`/compliance) ou d'une échelle
  par défaut (1/16, 1/8, 1/4, 1/2, 1).
- Le state est **une donnée sérialisable** (alist/plist) : c'est lui que
  liront/écriront l'agent (Spec D) et les ancres (Spec C).

### B2. Rendu

- Buffer dédié `*XIIIF View*`, `special-mode` dérivé, image unique centrée.
- Requête Image API : région = vue + **marge de préchargement** (1 écran
  autour), taille = dimension fenêtre × facteur HiDPI. **HiDPI** : détecter
  via `(frame-scale-factor)` quand disponible (Emacs 29+ ; sinon défaut 1),
  demander les pixels physiques et afficher avec `:scale (/ 1.0 facteur)` —
  sinon tout est flou sur Mac Retina.
- **Serveurs level-0** (M6) : ne jamais synthétiser de taille arbitraire ;
  choisir la plus proche parmi `sizes`/`tiles` advertisées (helper
  `xiiif-image-closest-size`, réutilisable par la vignette).
- **Proxy immédiat** : pendant un pan/zoom, réafficher l'image déjà en main
  redimensionnée (`:scale`) ; la version nette part via l'ordonnanceur et
  remplace au retour (`run-with-idle-timer` ~0.15 s pour coalescer).
- **Navigation** : pan par pas (flèches / hjkl, pas = ½ écran, `C-u` = pas
  fin), zoom par niveaux (`+`/`-`/`0`), `g` recharge, `q` quitte. Chaque
  navigation **annule le groupe** de fetchs de la vue précédente et met en
  file les préchargements des régions voisines en `:priority 'prefetch`.
- **Mémoire** : les images affichées passent par `image-flush` quand elles
  sortent d'un petit LRU local (~8 entrées) — le cache d'images d'Emacs
  n'évince que par temps, pas par taille.
- Terminal (`display-graphic-p` nil) : message clair + proposition d'ouvrir
  l'URL ; pas de crash.

### B3. Entrées/sorties

- `xiiif-view-canvas` (commande : depuis le canvas courant), `xiiif-view-region`
  (fonction : depuis un `xiiif-view-state` — utilisée par Spec C/D pour
  « saute à cette ancre »).
- `xiiif-view-copy-url` (URL Image API de la vue exacte), `xiiif-view-annotate`
  (→ Spec C), `xiiif-view-open-in-mirador` (→ Content State, Spec C).
- Touches depuis l'existant : dans le canvas detail (`v`) et le canvas
  browser (`v`) → ouvrir le viewer.

**Critères d'acceptation B.**
- Ouvrir une page Gallica, zoomer sur une lettrine, paner au clavier : aucune
  requête doublonnée (visible via un compteur de l'ordonnanceur), proxy flou
  immédiat puis net, retour sur une région déjà vue = zéro réseau (cache A3).
- Sur un serveur level-0 simulé (fixture), aucune URL hors `sizes` advertisées.
- Tests : géométrie (état ↔ région requêtée ↔ affichage), échelle de zoom
  dérivée d'un `info.json` fixture, HiDPI (facteur 2 simulé), éviction LRU.
  Le rendu lui-même est vérifié en batch avec des images fixtures locales
  (`file://`).

---

## 4. Spec C — Ancres canoniques, annotations, Content State

**Objectif.** La clé de voûte du système : un format d'ancre unique pour
« cet endroit précis de cette source », lu et écrit par xiiif, par l'agent
(via MCP, hors de ce dépôt) et par les visualiseurs web. Puis l'écriture :
transformer une région vue en note ancrée dans le vault de l'utilisateur.

### C1. Parser les régions existantes (corrige M1)

- `xiiif-region` : struct `(x y w h)` + parseurs :
  - fragment **Media Fragments** `#xywh=` (et `#xywh=percent:`) sur les
    cibles chaînes ;
  - `SpecificResource` → `selector` → `FragmentSelector` (`value` xywh) —
    v3 — et le `on`/`full`+`selector` v2 des hits de recherche.
- Porter la région dans `xiiif-annotation` (nouveau slot `region`) et
  `xiiif-search-hit` (idem). L'UI les affiche (colonne « Region » ou champ) ;
  `RET` sur un hit/annotation **avec** région ouvre le viewer à cette région
  (dépendance B, sinon dégrade vers le canvas detail).

### C2. Ancre canonique + IIIF Content State API

- Format d'ancre xiiif (alist sérialisable, stable, versionné) :
  `(:manifest URL :canvas ID :region (X Y W H) :label STR)` — région en
  pixels canvas pleine résolution, omissible (ancre = canvas entier).
- **Export** : `xiiif-content-state-url` — encoder l'ancre en annotation
  IIIF **Content State 1.0** (base64url du JSON) et produire l'URL
  `<viewer>?iiif-content=<state>`. `xiiif-open-in-mirador` gagne un argument
  optionnel ancre → **bascule précise** (canvas+région) au lieu du seul
  manifest (corrige M7).
- **Import** : `xiiif-content-state-parse` (URL ou base64) → ancre → 
  `xiiif-view-region` / canvas detail. Permet de coller un lien Content
  State venu d'ailleurs.

### C3. Écriture de notes ancrées (backend pluggable)

- `xiiif-annot-create` (commande, disponible dans le viewer et le canvas
  detail) : construit l'ancre du contexte courant, demande un titre/texte,
  puis délègue à `xiiif-annot-backend-function` (defcustom).
- **Backend par défaut `org`** (dans le paquet) : insère/append dans un
  fichier Org configurable une entrée contenant le lien manifest, l'ancre
  complète en drawer `:PROPERTIES:` (`:XIIIF_MANIFEST:`, `:XIIIF_CANVAS:`,
  `:XIIIF_REGION:`), le lien Content State, et le lien Image API de la
  région. Enrichir aussi `xiiif-org-metadata-block` (canvas-id + region +
  content-state) — aujourd'hui il s'arrête au canvas.
- Les backends personnels (Denote/Markdown/vault Obsidian de l'utilisateur)
  vivent **dans la config utilisateur, pas dans le paquet** — le paquet
  fournit le point d'extension et le backend org générique.
- Hors périmètre 0.4 (inchangé vs roadmap) : écrire des Web Annotations vers
  un serveur distant.

**Critères d'acceptation C.**
- Round-trip testé : ancre → Content State → parse → même ancre ;
  fixtures v2 (`on`+selector) et v3 (`SpecificResource`) pour C1.
- Un hit de recherche Gallica avec xywh ouvre le viewer sur la bonne région.
- `xiiif-annot-create` produit une entrée Org relisable dont l'ancre permet
  de revenir exactement à la vue (commande `xiiif-annot-visit` sur l'entrée
  au point).

---

## 5. Spec D — Surface batch / pilotage externe

**Objectif.** Qu'un processus externe (l'agent via `emacsclient --eval`, un
script) puisse piloter la console **sans UI interactive** : les variantes
synchrones existantes deviennent une surface documentée et complète.

- `xiiif-batch-open (url)` → charge (sync) et rend le manifest, retourne un
  résumé sérialisable (titre, nb canvases, structures p/a).
- `xiiif-batch-goto (anchor)` → ouvre viewer/canvas sur l'ancre (C2) ;
  accepte l'alist ancre ou une URL Content State.
- `xiiif-batch-current-view ()` → l'ancre de la vue courante (nil sinon).
- `xiiif-batch-annotate (anchor title body)` → C3 sans prompts.
- Garanties : pas de `read-string`/prompts dans ces chemins ; erreurs
  signalées (pas de `user-error` muets) ; docstrings avec exemples
  `emacsclient -e '(xiiif-batch-goto ...)'` dans le README (section
  « Scripting »).
- Note de conception : la *pull direction* (l'agent lit/écrit l'état de vue)
  suffit en 0.4. Pas de serveur, pas de websocket dans xiiif — si un « follow
  mode » temps réel est voulu un jour, il se fera côté config utilisateur.

**Critères d'acceptation D.**
- Une session `emacs -Q --batch` peut : charger un manifest fixture, produire
  une ancre, la convertir en Content State et créer une note org — sans
  aucune interaction. Test ERT batch dédié.

---

## 6. Spec E — Corrections & dette (à traiter au fil des sprints)

Priorité haute (bugs) :
1. **B1** double-callback `xiiif-annotations-collect` — refactor en deux
   phases (collecter les thunks, puis dispatcher ; le check final de
   complétion ne court plus pendant l'émission). Test de régression avec
   errback synchrone.
2. **B2** course de la vignette — handle buffer-local + annulation au
   re-rendu (ou compteur de génération). Test : deux rendus rapprochés.
3. **B3** `g` du buffer annotations — commande de refresh dédiée.

Priorité normale :
4. **D1** re-appliquer les marques après refresh (par canvas-id).
5. **D2** défaut de `xiiif-preferred-languages` dérivé de la locale.
6. Garde `xiiif-api-max-body-size` (voir A1).
7. Éviction cache HTTP (voir A3).
8. **D3** ROADMAP.md (« reflects 0.1.0 ») et typo Homepage upgrade.el.
9. **D4** pagination Search (`next`) et AnnotationCollection (`next`) —
   peut glisser en 0.5 si le temps manque, documenter alors la limite.
10. **D5** (optionnel) `xiiif-ocr-alto-boxes` : parser HPOS/VPOS/WIDTH/HEIGHT
    → liste de (STRING . REGION), pour la future superposition texte/région.

---

## 7. Ordre de mise en œuvre, jalons, contraintes

### Ordre recommandé (dépendances)

1. **Sprint 1 — fondations** : E1-E3 (bugs), A4 (JSON natif), A1 (backend
   plz commutable), garde de taille. Livrable : réseau plus rapide et sûr, à
   comportement identique.
2. **Sprint 2 — ordonnanceur + caches** : A2, A3, migration des appels
   internes vers `xiiif-fetch`. Livrable : politesse/dédup/priorités testées.
3. **Sprint 3 — ancres (données)** : C1, C2 (+ E9 si simple). Livrable :
   régions préservées partout, Content State aller-retour, Mirador précis.
   *(Indépendant du viewer — peut précéder ou suivre le sprint 4.)*
4. **Sprint 4 — viewer** : B complet, consommant A et C. Livrable : lecture
   rapprochée d'une page Gallica au clavier.
5. **Sprint 5 — écriture & batch** : C3, D, E4-E8, doc README (sections
   Viewer / Anchors / Scripting), CHANGELOG, bump 0.4.0.

### Contraintes projet (non négociables)

- **Compat** : Emacs 27.1+ (`Package-Requires` actuel). Les facilités 29+
  (`frame-scale-factor`…) toujours derrière `fboundp`.
- **Zéro dépendance obligatoire** : `plz` strictement optionnel, détecté à
  l'exécution. Org chargé paresseusement comme aujourd'hui.
- **Tests sans réseau** : tout nouveau comportement réseau testé via
  transport factice + fixtures `examples/` (en ajouter : `info.json`
  level-0, réponse Search avec xywh, AnnotationPage avec SpecificResource).
- **`make test` et `make compile-strict` verts à chaque sprint** ; CI
  existante inchangée.
- **Style** : conventions du dépôt (préfixes `xiiif-`/`xiiif--`, cl-lib ok,
  docstrings première-ligne impérative, defcustom groupés) ; code, README,
  CHANGELOG **en anglais** ; commits atomiques par spec, messages de la
  forme existante (`feat:`/`fix:` observés dans l'historique récent).
- **Philosophie** : text-first ; le viewer est une console, pas un Mirador.
  En cas d'arbitrage, préférer la simplicité + la bascule web au réglage de
  performance héroïque.

### Hors périmètre explicite (ne pas faire)

- Deep-zoom continu, rendu souris/rubber-band, xwidgets.
- Écriture d'annotations vers des serveurs distants.
- Tout ce qui concerne l'agent lui-même (MCP, OpenScience) : autre dépôt.
- SQLite / index de grosses collections (roadmap 0.5+).
