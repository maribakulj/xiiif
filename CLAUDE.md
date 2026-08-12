# CLAUDE.md — xiiif

## Où tu es

Package Emacs mûr : v0.4.0, 23 fichiers `.el`, 33 fichiers de tests ERT, CI verte. **C'est le
seul dépôt du chantier où l'essentiel de la V1 est déjà écrit.** Un `ROADMAP.md`, un `PLAN-0.4.md`
et un `SPECS-0.4.md` existent et sont à jour — ne les réaudite pas.

## Règle dure

Ne transforme pas xiiif en serveur agentique, en worker ou en serveur MCP. C'est un viewer humain
(ADR 0007). L'intégration Locus est **facultative** et passe par `locusolus/apps/emacs`, jamais
par un accès direct à une base. xiiif lit `ArtifactManifest` comme une donnée et n'importe aucun
code Locus.

## Priorité : ce qui est déverrouillé aujourd'hui

Ces six items ne dépendent d'aucun autre dépôt et peuvent partir immédiatement :

1. ~~`xiiif-open` — dispatcher générique~~ — **fait**. La détection manifest / collection
   existait déjà dans `xiiif-open-manifest` ; ce qui manquait était la reconnaissance du Canvas
   isolé (`xiiif-resource-kind`) et le tri Content State / ressource avant le réseau
   (`xiiif-open-target-kind`). `xiiif-open` n'était qu'un `defalias`.
2. ~~Alias d'API du `SPEC_V1.md` §15~~ — **fait**. Un seul était un vrai alias
   (`xiiif-search-ocr` → `xiiif-search`). `xiiif-create-annotation` et
   `xiiif-open-external-viewer` sont des façades qui prennent des arguments que la commande
   sous-jacente n'acceptait pas ; `xiiif-export-content-state` était une commande absente — les
   briques existaient dans `xiiif-anchor.el`, rien ne les exposait à l'utilisateur.
   Restent hors de §15 : `xiiif-select-region` (item 3) et `xiiif-open-locus-artifact` (bloqué).
3. ~~`xiiif-select-region`~~ — **fait**. Deux commandes : `xiiif-view-select-region` (`r` dans
   la visionneuse, l'invite pré-remplie avec la région affichée) et `xiiif-select-region`, qui
   ouvre la visionneuse déjà cadrée. Hors affichage graphique elle copie l'URL Image API de la
   région : §23 demande que l'image rendue ne soit jamais le seul moyen d'atteindre une région.
4. ~~**Politique d'URL**~~ — **fait** (`xiiif-url.el`) : schémas autorisés, hôtes internes
   refusés (`169.254.169.254` inconditionnellement), redirections bornées sur les deux
   transports. Reste dû : réinspecter **chaque saut** d'une redirection, que les deux transports
   suivent en interne sans exposer les cibles.
5. ~~**Limite de profondeur** sur les réponses~~ — **fait** (`xiiif-json.el`,
   `xiiif-json-max-depth`, 100, erreur `xiiif-json-too-deep` dérivée de `xiiif-parse-error`).
   La limite de **taille** existait déjà avant ce chantier — `xiiif-api-max-body-size`, 50 Mo.
   La profondeur est vérifiée **après** parsing et par un parcours itératif : le risque n'est
   pas le parseur (les deux lecteurs refusent déjà l'absurde) mais les walkers récursifs en
   aval, et une vérification récursive serait elle-même la vulnérabilité.
6. Bridge **OpenSeadragon**, symétrique de Mirador. Zéro occurrence dans le code actuel.

XXE : sans objet par construction — `xiiif-ocr.el` scanne le XML par regexp sans
`libxml-parse-xml-region`, donc aucune résolution d'entité. Ne « corrige » pas ce qui n'est pas
cassé, mais ajoute les limites de taille.

## Bloqué sur `locusolus/packages/protocol`

`RemoteArtifactRef`, `xiiif-open-locus-artifact`, l'affichage séparé identité / live / snapshot /
intégrité / divergences (§19), la revue humaine `accept` / `needs-correction` / `wrong-target` /
`source-changed` (§20). N'invente pas ces schémas ici.

---

## Identité

- Locus Solus = laboratoire/control plane.
- Canterel = runtime scientifique agentique.
- LEP = protocole générique d’exécution.
- `locusd` = daemon Locus Solus.
- `locus-execd` = broker d’exécution privilégié lorsque nécessaire.
- `locus` = CLI.
- `locusolus/apps/emacs` = client Emacs produit, dans le monorepo (ADR 0009).
- xiiif = viewer IIIF humain.

## Invariants non négociables

1. Le domaine ne dépend pas du backend de déploiement.
2. PostgreSQL/event store et graphe Locus sont la vérité institutionnelle, pas les transcripts.
3. Un worker ne modifie jamais directement la base canonique.
4. Tout résultat scientifique majeur est artifact-first et provenance-first.
5. L’exécution non fiable se fait dans une sandbox réelle avec limites et attestation.
6. Les ressources sont réservées avant exécution ; elles ne sont pas supposées illimitées.
7. Temporal est un backend, pas une abstraction métier.
8. Le GPU est une capability, pas une dépendance globale.
9. Emacs commande et inspecte ; le web rend les visualisations riches.
10. xiiif n’est pas requis par les agents.
11. Les reviewers indépendants ne reçoivent pas le raisonnement privé ou le contexte non autorisé du générateur.
12. Les résultats négatifs et conflits ne sont jamais supprimés pour rendre le graphe “propre”.

## Qualité du code

- simplicité avant abstraction spéculative ;
- types stricts ;
- schémas versionnés ;
- pas de fonctions géantes ;
- pas de duplication cross-repo des contrats ;
- erreurs structurées ;
- timeouts et cancellation ;
- logs corrélés sans secrets ;
- tests unitaires + contract + integration selon couche ;
- aucune dépendance implicite à une machine de développeur.

## Git

Un commit = objectif cohérent et testable. Ne mélange pas rename massif, refactor, nouvelle fonctionnalité et bugfix sans nécessité. Les migrations importantes ont un ADR et un plan de rollback.

## Sécurité

Ne monte jamais le home utilisateur, le socket Docker/Podman ou un répertoire de secrets dans une sandbox par défaut. Ne logge ni OAuth token, API key, cookie ni contenu classifié. Réseau deny-by-default pour code non fiable.

---

## Note d'origine du handoff

Ne transforme pas xiiif en serveur agentique. Priorité à l’UX Emacs, async, parsing IIIF/OCR, annotations, Content State, sécurité et ouverture Mirador/OpenSeadragon. L’intégration Locus est facultative et passe par son client public.
