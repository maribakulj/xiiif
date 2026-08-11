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

1. `xiiif-open` — dispatcher générique (manifest / collection / Content State / canvas). Seul
   `xiiif-open-manifest` existe.
2. Alias d'API du `SPEC_V1.md` §15 : `xiiif-create-annotation` (→ `xiiif-annot-create`),
   `xiiif-export-content-state`, `xiiif-search-ocr`, `xiiif-open-external-viewer`.
3. `xiiif-select-region` — sélection numérique de région au clavier (§23). Le modèle existe dans
   `xiiif-region.el`, l'interaction dans `xiiif-view.el` ; la commande manque.
4. **Politique d'URL** : schémas autorisés, hôtes internes refusés (`169.254.169.254` compris),
   redirections bornées. Aucune politique n'existe aujourd'hui — grep sans résultat sur tout le
   dépôt.
5. **Limites de taille et de profondeur** sur les réponses. Absentes.
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
