# IMPLEMENTATION_LEDGER

Un exemplaire par dépôt, à la racine. Ajout en fin de fichier, jamais de réécriture d'une entrée
passée : c'est un journal, pas un état.

Une session de code se termine en ajoutant une entrée. Une session qui n'en produit pas n'a rien
livré, quoi qu'elle ait écrit.

## Format

<!-- prettier-ignore -->
```markdown
## AAAA-MM-JJ — <id roadmap> — <titre>

**Périmètre.** Fichiers touchés, une ligne. Si le périmètre a débordé de l'item, dire pourquoi.
**Tests exécutés.** Commande et résultat. Le test de sortie de l'item, nommément.
**Décisions prises.** Seulement celles qui contraignent la suite. Une décision qui mérite un ADR
reçoit un ADR et est référencée ici, pas décrite ici.
**Écart avec la spec.** Ce qui a été fait autrement, et pourquoi. « Aucun » est fréquent et valide.
**Prochain item.** Identifiant + vérification que ses dépendances sont satisfaites.
```

## Règles

Le périmètre déclaré doit correspondre au diff. Un débordement signale soit un découpage trop fin,
soit un couplage non anticipé — les deux méritent une ligne.

Une migration `[M]` inscrit son plan de rollback dans l'entrée.

Un test de sortie qui ne passe pas laisse l'item ouvert. On peut committer du code incomplet ; on
n'écrit pas « terminé ».

## Entrées

## 2026-08-12 — W10.4 — politique d'URL et redirections bornées

Item pris en repli : `docs/10_V1_ROADMAP.md` §W10 désigne les six items xiiif comme « bon travail
de repli quand une décision bloque ailleurs », et W0.5 côté `locusolus` attend l'approbation
d'ADR 0011.

**Périmètre.** `xiiif-url.el` (neuf), `xiiif-errors.el` (une erreur), `xiiif-api.el` (le prédicat
délègue, six points d'appel, borne de redirection sur les deux transports), `xiiif-ocr.el` (un
point d'appel), `xiiif.el` (chargement du module), `tests/xiiif-url-test.el` (neuf),
`tests/xiiif-backend-plz-integration-test.el` (une liaison), `CLAUDE.md` (deux corrections
factuelles), et ce fichier. Débordement déclaré : la création de ce ledger appartient à W0.10 ;
elle est faite ici parce qu'une session se termine en ajoutant une entrée et qu'il n'y avait pas
de fichier où l'ajouter.

**Tests exécutés.** `make test` → 407 tests, 402 conformes, 0 inattendu, 5 sautés (plz et curl
absents de la machine). `make compile-strict` → 0, avertissements traités en erreurs. Les neuf
tests neufs couvrent ce que la politique refuse **et** ce qu'elle doit continuer de laisser
passer — une politique qui bloque des hôtes IIIF ordinaires se fait désactiver en bloc par le
premier utilisateur qu'elle gêne, ce qui est pire que pas de politique.

**Décisions prises.** Deux tiers de refus, et c'est la décision structurante. Les adresses
link-local et de métadonnées cloud — `169.254.169.254` en tête — sont refusées **quel que soit le
réglage** : aucun service IIIF n'y a jamais vécu, et c'est là que se vole une identité
d'instance. Les hôtes loopback et privés sont refusés **par défaut** et s'ouvrent par
`xiiif-url-allow-private-hosts` : faire tourner un Cantaloupe local est une pratique ordinaire,
donc c'est un choix de politique, pas une règle — mais un choix que l'utilisateur pose
explicitement. Le message de refus nomme le réglage à basculer, sans quoi il est inactionnable.

Le prédicat existant `xiiif-api--valid-url-p` a été conservé comme façade et délègue à la
politique : les six points d'appel n'ont pas eu à changer de forme, et `xiiif-url-refused` dérive
de `xiiif-network-error` pour que les gestionnaires existants continuent de l'attraper.

**Écart avec la spec.** Un manque, assumé et nommé plutôt que caché. `SPEC_V1.md` §13 demande la
« prévention SSRF » ; ce qui est livré valide l'URL **initiale** et borne le **nombre** de
redirections, mais ne réinspecte pas chaque saut : les deux transports suivent les redirections
en interne et xiiif n'en voit pas les cibles. Une URL publique qui redirige vers une adresse
privée reste donc atteignable. Fermer ce trou demande de suivre les redirections à la main dans
`xiiif-api` — c'est l'item de suite le plus évident de ce chantier, et la borne de comptage est
ce qui limite les dégâts d'ici là.

Par ailleurs, deux corrections factuelles au `CLAUDE.md` de ce dépôt : il annonçait les limites
de taille comme absentes alors que `xiiif-api-max-body-size` existe depuis avant ce chantier (50
Mo, avec `xiiif-body-too-large`) ; ce qui manque réellement est la limite de **profondeur** JSON.
Et l'item 4 est désormais fait.

**Prochain item.** Les cinq autres items de §W10, tous encore sans dépendance :
`xiiif-open` dispatcher, alias d'API §15, `xiiif-select-region`, limite de profondeur JSON,
bridge OpenSeadragon. Le retour sur `locusolus` W0.5 dépend de l'approbation d'ADR 0011 (PR #6),
qui débloque aussi la garde Rust (#7) et W0.4 (#8).

## 2026-08-12 — W10.1 — `xiiif-open`, dispatcher générique

Item pris en repli pour la même raison qu'à l'entrée précédente : `locusolus` W0.5 attend
l'approbation d'ADR 0011.

**Périmètre.** `xiiif-core.el` (`xiiif-canvas-p-json` neuf, `xiiif-resource-kind` élargi),
`xiiif.el` (`xiiif--load-resource-async` prend un quatrième callback, `xiiif-open-manifest`
route le Canvas, le `defalias` `xiiif-open` devient une commande, `xiiif-open-target-kind`
neuf), `tests/xiiif-open-test.el` (neuf), `README.md` (le quick start passe par `xiiif-open`,
la table ne le décrit plus comme un alias), `CLAUDE.md` et ce fichier.

**Tests exécutés.** Test de sortie : `xiiif-open` accepte les quatre formes de cible du §15 et
choisit la bonne destination. `make test` → 419 tests, 414 conformes, 0 inattendu, 5 sautés
(plz et curl absents). `make compile-strict` → 0. Les douze tests neufs séparent les deux
décisions : ce qui se tranche sur la forme, sans réseau (`xiiif-open-target-kind`), et ce qui se
tranche sur le JSON reçu (`xiiif-resource-kind`).

**Décisions prises.** Le dispatch se fait en deux temps, et c'est ce qui rend la commande
testable hors réseau. Distinguer un Content State d'une URL de ressource est décidable sur la
chaîne seule — le premier est auto-descriptif. Distinguer une URL de Manifest d'une URL de
Canvas ne l'est pas : rien dans l'URL ne le dit, il faut le JSON. Donc premier temps hors
réseau, second temps dans le callback existant.

L'ordre de `xiiif-resource-kind` est significatif : le Canvas est testé **avant** le Manifest.
Un Canvas porte `items` lui aussi, et le repli v2 pour une racine sans type l'aurait réclamé
comme Manifest. Le test `canvas-wins-over-the-manifest-fallback` fixe cet ordre.

Une URL que la politique refuse échoue **comme URL**. La tentation était de la repasser en
token base64url après échec ; elle enterrerait la raison du refus derrière un « Content State
illisible ». Le message nomme donc le réglage à basculer, comme en W10.4.

Le quatrième callback de `xiiif--load-resource-async` est optionnel : les appelants qui n'ont de
sens que pour un Manifest ne le passent pas, et un Canvas leur est signalé comme non supporté
plutôt que forcé dans le mauvais tampon.

**Écart avec la spec.** Aucun sur cet item. `SPEC_V1.md` §15 liste aussi
`xiiif-open-external-viewer` et `xiiif-open-locus-artifact` : le premier est l'item §W10-2, le
second reste bloqué sur `locusolus/packages/protocol`.

**Prochain item.** §W10 : alias d'API §15, `xiiif-select-region`, limite de profondeur JSON,
bridge OpenSeadragon — aucun n'a de dépendance. Le retour sur W0.5 reste conditionné à
l'approbation d'ADR 0011 (PR #6 `locusolus`), qui débloque aussi #7 et #8.

## 2026-08-12 — W10.2 — l'API `SPEC_V1.md` §15

Toujours en repli : ADR 0011 (PR #6 `locusolus`) attend l'arbitrage.

**Périmètre.** `xiiif-search.el` (`xiiif-search-ocr`, et le message d'absence de service),
`xiiif-annot.el` (`xiiif-create-annotation`), `xiiif.el` (`xiiif-export-content-state`,
`xiiif-open-external-viewer`), `tests/xiiif-api-surface-test.el` (neuf), `README.md`,
`CLAUDE.md` et ce fichier.

**Tests exécutés.** Test de sortie : les sept noms de §15 livrables aujourd'hui sont liés et
sont des commandes — c'est l'assertion qui fait de §15 un contrat plutôt qu'une liste de vœux.
`make test` → 433 tests, 428 conformes, 0 inattendu, 5 sautés. `make compile-strict` → 0.
Quatorze tests neufs.

**Décisions prises.** L'item s'appelait « alias d'API » ; un seul des quatre en était un. Le
constat vaut d'être écrit, parce qu'il change ce qu'il fallait livrer :

- `xiiif-search-ocr` est un vrai alias de `xiiif-search`, posé par `defalias` avec sa propre
  docstring. Un service IIIF Search 1.0 indexe l'OCR produit par l'institution : chercher dans
  ce service **est** chercher dans l'OCR, et c'est le seul moyen de couvrir un manifest entier
  sans télécharger chaque sidecar. Le test compare les objets fonction, pas les noms, pour
  qu'une copie divergente échoue.
- `xiiif-create-annotation` et `xiiif-open-external-viewer` sont des façades. Elles prennent des
  arguments que la commande sous-jacente n'accepte pas — un ancre explicite, un titre, un corps,
  un choix de visionneuse — pour qu'un seul nom serve l'appel interactif et l'appel programmé.
  `xiiif-annot-create` et `xiiif-open-in-mirador` restent inchangés : ils sont liés dans des
  keymaps.
- `xiiif-export-content-state` était une commande absente, pas un renommage. `xiiif-anchor.el`
  savait déjà produire les trois formes ; rien ne les exposait. La commande suit la convention
  de `xiiif-export-citation` — insertion au point si le tampon est modifiable, kill ring sinon.

Une seule commande de visionneuse existe aujourd'hui, donc `xiiif-open-external-viewer` fait un
`pcase` à une branche plutôt qu'un registre `defcustom`. Le registre viendra avec le second
client (bridge OpenSeadragon, item 6) — pas avant : à une entrée, ce n'est pas un choix.

Enfin, le message d'erreur de `xiiif-search` quand le manifest ne déclare pas de service nomme
désormais `xiiif-show-ocr`. Sans service il n'y a rien à interroger à distance, mais le canvas
courant peut porter un sidecar : dire lequel transforme une impasse en étape suivante.

**Écart avec la spec.** §15 liste neuf noms ; sept sont livrés. `xiiif-select-region` est
l'item 3 de §W10, non commencé. `xiiif-open-locus-artifact` reste bloqué sur
`locusolus/packages/protocol`. Les deux sont nommés en commentaire dans le fichier de tests,
avec leur blocage — mais **pas** assertés absents : un test qui devient rouge le jour où la
fonctionnalité arrive est une mauvaise alarme.

**Prochain item.** §W10 : `xiiif-select-region`, limite de profondeur JSON, bridge
OpenSeadragon. Aucun n'a de dépendance ; `xiiif-select-region` est le plus proche de ce qui
vient d'être touché. W0.5 reste conditionné à l'approbation d'ADR 0011.

## 2026-08-12 — W10.3 — `xiiif-select-region`, sélection numérique au clavier

Toujours en repli : ADR 0011 (PR #6 `locusolus`) attend l'arbitrage.

**Périmètre.** `xiiif-region.el` (`xiiif-region-valid-p`), `xiiif-view.el`
(`xiiif-view-select-region`, touche `r`), `xiiif.el` (`xiiif-select-region`),
`tests/xiiif-select-region-test.el` (neuf), `README.md`, `CLAUDE.md` et ce fichier.

**Tests exécutés.** Test de sortie : une région se saisit au clavier et se lit au clavier, sans
pointeur et sans affichage graphique. `make test` → 444 tests, 439 conformes, 0 inattendu, 5
sautés. `make compile-strict` → 0. Onze tests neufs.

**Décisions prises.** §23 tient en deux phrases, et la seconde — « les previews graphiques ne
doivent pas être la seule manière de connaître les coordonnées ou la cible » — a dicté deux
choses qu'une lecture rapide aurait manquées.

D'abord, **l'invite est pré-remplie avec la région affichée**. C'est le mécanisme entier de la
seconde phrase : ouvrir l'invite est la façon de lire les coordonnées courantes, et les modifier
est la façon de s'y déplacer. Une invite vide aurait satisfait « saisie numérique » sans
satisfaire « connaître les coordonnées ».

Ensuite, **hors affichage graphique la commande ne meurt pas** : elle copie l'URL Image API de
la région dans le kill ring. Une région qu'on ne peut pas voir reste une région qu'on peut
citer. La solution facile — refuser hors terminal graphique — aurait laissé §23 à moitié faite
précisément dans le cas où elle compte le plus.

Deux commandes plutôt qu'une, parce que les contextes n'ont pas le même défaut : dans la
visionneuse la région courante existe et sert d'amorce, ailleurs il n'y en a pas.
`xiiif-select-region` délègue à `xiiif-view-select-region` par `derived-mode-p`, et la touche
`r` est liée à la seconde.

`xiiif-region-valid-p` vit dans `xiiif-region.el` et pas dans la commande : c'est une propriété
du modèle, pas de l'interaction. Elle refuse une extension nulle ou négative et une origine
négative, et pour une région en pourcentage vérifie qu'elle reste dans le canvas — la seule
borne haute vérifiable sans connaître les dimensions. Un test vérifie qu'une région refusée
laisse la vue **exactement** où elle était.

**Écart avec la spec.** Aucun sur cet item. §15 est désormais à huit noms sur neuf ; seul
`xiiif-open-locus-artifact` manque, bloqué sur `locusolus/packages/protocol`.

**Prochain item.** §W10 : limite de profondeur JSON, bridge OpenSeadragon. Sans dépendance
l'un comme l'autre. W0.5 reste conditionné à l'approbation d'ADR 0011.

## 2026-08-12 — W10.5 — limite de profondeur JSON

Toujours en repli : ADR 0011 (PR #6 `locusolus`) attend l'arbitrage.

**Périmètre.** `xiiif-json.el` (neuf), `xiiif-errors.el` (une erreur), `xiiif-api.el`
(`xiiif-api--parse-json` devient une façade), `xiiif-anchor.el` (le parse de Content State passe
par le même décodeur), `tests/xiiif-json-test.el` (neuf), `README.md`, `CLAUDE.md` et ce
fichier.

**Tests exécutés.** Test de sortie : un document imbriqué au-delà de la limite est refusé
avec `xiiif-json-too-deep`, sur les deux entrées — réponse HTTP et Content State collé.
`make test` → 456 tests, 451 conformes, 0 inattendu, 5 sautés. `make compile-strict` → 0.
Douze tests neufs.

**Décisions prises.** La menace n'est pas celle qu'on croit, et c'est ce qui a décidé du
placement. Les deux lecteurs JSON refusent déjà l'imbrication absurde — le natif par sa propre
garde de profondeur, celui en Elisp par `max-lisp-eval-depth` — et les deux échecs arrivent
comme `xiiif-parse-error`. Le vrai risque est un document qui **parse avec succès** à deux
mille niveaux et fait ensuite exploser les walkers récursifs en aval : la conversion v2→v3, le
lecteur de sélecteurs, les renderers. Chacun échouerait loin du fetch, avec une erreur qui ne
nomme rien de tout cela.

Donc la limite porte sur ce qui entre dans le modèle, pas sur ce que le parseur tolère —
vérification **après** parsing — et elle est à nous plutôt qu'héritée de la borne que le
Emacs courant a compilée.

Le parcours est itératif, avec une pile explicite. Une vérification récursive sur une entrée
hostile épuiserait exactement la pile qu'elle protège : la vérification deviendrait la
vulnérabilité. C'est le test qui porte le plus : 5 000 niveaux parcourus intégralement sous une
limite qui les autorise, puis refusés sous une limite qui ne les autorise pas.

Un seul décodeur pour tout ce qui entre de l'extérieur. `xiiif-anchor.el` dupliquait les
`json-object-type` et compagnie ; un Content State collé est aussi peu fiable qu'un manifest
récupéré, et rien ne justifiait deux chemins. `xiiif-api--parse-json` reste comme façade — trois
appelants et deux tests l'utilisent.

`xiiif-json-too-deep` dérive de `xiiif-parse-error` : les gestionnaires existants continuent
d'attraper. Un test le vérifie explicitement plutôt que de le supposer.

La limite par défaut est 100, soit un ordre de grandeur au-dessus du réel — une Collection de
Manifests de Canvases d'AnnotationPages tient sous dix. Un test vérifie que **tous** les
fixtures d'exemple du dépôt passent à un quart de la limite. Une limite qui refuse du IIIF
ordinaire se fait mettre à nil par le premier utilisateur qu'elle bloque, ce qui est pire que
pas de limite : la marge fait partie de la garde.

**Écart avec la spec.** Aucun sur cet item. Reste dû sur §13, et inchangé depuis W10.4 :
réinspecter chaque saut d'une redirection.

**Prochain item.** §W10 : bridge OpenSeadragon, dernier item déverrouillé du dépôt. W0.5 reste
conditionné à l'approbation d'ADR 0011 (PR #6 `locusolus`).

## 2026-08-12 — W10.6 — bridge OpenSeadragon

Dernier des six items §W10. Toujours en repli : ADR 0011 (PR #6 `locusolus`) attend l'arbitrage.

**Périmètre.** `xiiif-osd.el` (neuf), `xiiif.el` (`xiiif-open-in-openseadragon`,
`xiiif-default-external-viewer`, le dispatcher gagne sa seconde branche), `xiiif-view.el`
(`xiiif-view-open-in-openseadragon`, touche `O`), `tests/xiiif-osd-test.el` (neuf), `README.md`,
`CLAUDE.md` et ce fichier.

**Tests exécutés.** Test de sortie : la page générée ouvre le bon `info.json`, cadrée sur la
région courante, et une URL de service hostile n'y écrit pas de balise. `make test` → 473 tests,
468 conformes, 0 inattendu, 5 sautés. `make compile-strict` → 0. Dix-sept tests neufs.

**Décisions prises.** L'item disait « symétrique de Mirador ». Il ne peut pas l'être, et
c'est le constat qui a décidé de tout le reste. Mirador est une application hébergée qui parle
Content State : lui passer une localisation est une URL. OpenSeadragon est une **bibliothèque
JavaScript** — pas d'instance canonique où envoyer qui que ce soit, aucune notion de Manifest ni
de Canvas, et ce qu'il consomme est un `info.json` d'Image API. Un handoff par URL n'existe pas ;
prétendre le contraire aurait produit une commande qui ne marche jamais.

Le module écrit donc une petite page autonome dans un fichier temporaire et l'ouvre. Deux
conséquences assumées : le handoff vise **un canvas**, jamais un manifest — c'est ce
qu'OpenSeadragon fait bien, et Mirador reste le handoff d'une œuvre entière ; et la page charge
la bibliothèque depuis `xiiif-osd-library-url`, un CDN par défaut, qui est un point de
configuration précisément pour qu'une machine hors ligne ou soucieuse de sa vie privée le pointe
vers une copie locale.

La région survit au handoff, et l'arithmétique se fait dans le navigateur — il connaît déjà les
dimensions de l'image, les calculer ici coûterait un `info.json`.

**Sur l'échappement**, qui est le vrai point dur : ce module introduit une frontière HTML/JS
qu'aucun autre n'a. Échapper pour JSON ne suffit pas, parce qu'un parseur HTML lit l'élément
`script` avant JavaScript : `</script>` le termine depuis l'intérieur d'une chaîne, et un
`<!--<script` antérieur bascule le tokeniseur dans un état où le `</script>` suivant ne le
termine plus. Plutôt qu'énumérer ces cas, **aucun `<` ne survit littéralement** — `<` est
ce que JavaScript y lit, et c'est du JSON ordinaire.

Deux bugs de ma part attrapés ici, tous deux par le test de round-trip et non par les tests de
motif : la chaîne de remplacement passée à `replace-regexp-in-string` avec LITERAL non nil est
insérée telle quelle, donc `"\\\\/"` ajoutait une contre-oblique de trop dans l'URL. Le test qui
relit la valeur échappée et la compare à l'originale attrape un caractère ajouté aussi bien
qu'un caractère perdu ; un test qui cherche un motif interdit n'attrape que le second. Et le
comptage des **deux** moitiés — `</script>` *et* `<script` — est ce qui a rendu la seconde porte
visible : compter seulement `</script>` passait au vert pendant que `<script` passait toujours.

L'URL du service est validée par la politique d'URL **avant** l'écriture du fichier (§13 :
« external viewer ouvre des URLs validées »), même si c'est le navigateur qui va chercher.

Enfin, le registre de visionneuses annoncé en W10.2 arrive maintenant qu'il y a deux clients, et
sous la forme que §8 demande : `xiiif-default-external-viewer` vaut `auto` et choisit **par
capacité** — OpenSeadragon quand un canvas zoomable est dans le contexte, Mirador sinon, et
Mirador dès qu'une ancre explicite est donnée puisqu'une ancre est une localisation, sa monnaie.
Le viseur choisi est toujours nommé dans l'écho : `auto` n'est jamais silencieux.

**Écart avec la spec.** §8 liste un troisième client, « une URL Locus Solus si l'artefact
appartient à une campagne » : bloqué sur `locusolus/packages/protocol`, comme le reste de
l'intégration Locus. Il prendra une troisième branche du même `pcase`.

**Prochain item.** Les six items §W10 sont faits. Ce qui reste dans ce dépôt est bloqué sur
`locusolus/packages/protocol` — `RemoteArtifactRef`, `xiiif-open-locus-artifact`, l'affichage
§19, la revue humaine §20 — à une exception près : réinspecter chaque saut d'une redirection
(§13), nommé comme dû depuis W10.4. Côté `locusolus`, W0.5 attend toujours l'approbation
d'ADR 0011 (PR #6), qui débloque aussi #7 et #8.
