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
