# xiiif — Spécification V1 du viewer et éditeur IIIF expert pour Emacs

## 0. Statut

Ce document remplace les spécifications précédentes qui donnaient à xiiif un rôle de service agentique ou de producteur canonique de preuves. La V1 décrite ici est volontairement plus nette : **xiiif est d’abord un instrument humain**.

Les mots DOIT, NE DOIT PAS, DEVRAIT et PEUT sont normatifs.

## 1. Vision

xiiif transforme Emacs en poste de lecture, inspection et annotation IIIF pour un utilisateur expert. Il doit être rapide, scriptable, non bloquant et interopérable avec Locus Solus, sans devenir une dépendance du laboratoire ni des agents.

Ses responsabilités principales :

- ouverture de manifests/collections IIIF ;
- navigation canvases/ranges/annotations ;
- inspection Image API et Content States ;
- OCR/ALTO et texte adressable ;
- sélection de région et annotations ;
- comparaison et contrôle des artefacts IIIF produits par des agents ;
- ouverture transparente de Mirador/OpenSeadragon lorsqu’un rendu web est supérieur ;
- liens Org et capture documentaire.

## 2. Non-responsabilités

xiiif NE DOIT PAS :

- orchestrer des agents ;
- connaître le moteur de workflow de Locus Solus ;
- gérer des budgets ou des reviews ;
- être requis pour démarrer Locus Solus ou Canterel ;
- servir de sandbox ;
- être le client IIIF obligatoire des agents ;
- stocker la vérité canonique du graphe ;
- réimplémenter Mirador, OpenSeadragon ou un navigateur complet dans Elisp.

## 3. Relation avec les agents

Les agents Canterel utilisent des outils headless : clients Presentation/Image/Search API, parseurs ALTO/PageXML/Web Annotation, téléchargement d’images, VLM, OCR et éventuellement Playwright. Ils produisent des artefacts standards :

```text
evidence/
├── manifest-snapshot.json
├── manifest.sha256
├── content-state.json
├── annotation.jsonld
├── canvas-region.png
├── ocr-fragment.txt
├── ocr-context.json
└── report.md|html
```

xiiif sait ouvrir ces artefacts après coup. Il n’est pas invoqué comme UI robotique pendant l’exécution.

## 4. Architecture

```text
Emacs
└── xiiif.el
    ├── async HTTP client
    ├── IIIF parser/model
    ├── cache
    ├── image/OCR/annotation model
    ├── Org links/capture
    ├── Locus artifact adapter
    └── external viewer bridge
         ├── Mirador
         └── OpenSeadragon
```

Le cœur logique doit rester testable sans UI. Les appels réseau sont asynchrones et annulables.

## 5. Compatibilité

V1 :

- IIIF Presentation API 3.x prioritaire ;
- lecture Presentation 2.x avec normalisation explicite ;
- Image API 2/3 utiles au corpus ;
- Web Annotation / AnnotationPage ;
- Content State ;
- IIIF Search lorsque disponible ;
- ALTO XML et texte OCR ;
- authentification IIIF uniquement si implémentée de façon sûre, sinon dégradation explicite.

Aucune conversion silencieuse ne doit perdre l’identité du canvas, de la région ou de la source.

## 6. Modèle local

Types internes minimaux : `ManifestRef`, `CollectionRef`, `CanvasRef`, `RangeRef`, `AnnotationRef`, `ImageServiceRef`, `ContentState`, `RegionSelection`, `OCRFragment`, `LocalAnnotation`, `RemoteArtifactRef`.

Ces objets servent à l’interface ; ils ne prétendent pas être le schéma épistémique de Locus Solus.

## 7. Buffers et UX

### 7.1 Manifest

Affiche métadonnées essentielles, ranges, nombre de canvases, services, droits et provenance. Navigation par `RET`, `n/p`, recherche et transient.

### 7.2 Canvas

Affiche label, dimensions, images, OCR/annotations, liens vers région courante, dérivés et artefacts liés.

### 7.3 OCR

Vue synchronisée avec canvas ; recherche ; copie/citation ; comparaison original/correction ; ouverture de l’élément ALTO si identifiants disponibles.

### 7.4 Annotation

Création/édition locale, commentaire, tags, motivation, body/target, export Web Annotation/Content State.

### 7.5 Region selection

La sélection peut être créée par coordonnées, depuis une image affichée ou via viewer web. Elle produit toujours une représentation sérialisable et reproductible.

## 8. Rendu image

xiiif peut afficher des dérivés raisonnables avec les capacités natives d’Emacs. Pour zoom profond, comparaison multi-canvas, overlays complexes ou annotations visuelles riches, `xiiif-open-external-viewer` ouvre :

- Mirador pour workspace IIIF riche ;
- OpenSeadragon pour image/zoom/overlays ;
- une URL Locus Solus si l’artefact appartient à une campagne.

Le choix est configurable et détecte les capacités disponibles.

## 9. Intégration Locus Solus

Intégration facultative via le client `locusolus/apps/emacs`, jamais via accès direct à PostgreSQL.

Actions :

- ouvrir une référence/artefact IIIF depuis une branche ;
- envoyer à Locus une `EvidenceReference`/annotation créée manuellement ;
- associer un Content State à un claim en staging ;
- comparer la source actuelle avec le snapshot utilisé par un run ;
- signaler une divergence ou annotation humaine.

Locus Solus possède la promotion canonique et la provenance globale.

## 10. Artifact interoperability

xiiif DOIT ouvrir un bundle produit par un agent même si celui-ci n’a jamais utilisé xiiif. Il vérifie hashes lorsqu’ils sont disponibles, montre le snapshot et la ressource live séparément et avertit des différences.

## 11. Org

Liens `iiif:` et `locus-iiif:` ; capture d’un canvas/région/OCR ; export d’URL/Content State ; propriété de source et hash ; aucun binaire massif incorporé dans le fichier Org par défaut.

## 12. Cache

Cache HTTP supprimable séparé des snapshots/artefacts. ETag/Last-Modified respectés. Taille et TTL configurables. Le cache ne constitue jamais une preuve d’intégrité.

## 13. Sécurité

- XML avec entités externes désactivées ;
- limites de taille/profondeur ;
- prévention SSRF pour URLs non sûres selon politique ;
- redirections bornées ;
- aucun HTML/JS distant évalué dans Emacs ;
- SVG distant traité comme non fiable ;
- credentials via `auth-source`, jamais logs ;
- fichiers téléchargés stockés hors répertoires exécutables ;
- external viewer ouvre des URLs validées.

## 14. Performance

- UI non bloquante ;
- pagination/lazy loading des collections et annotations ;
- dérivés Image API adaptés à la taille de fenêtre ;
- préchargement borné du canvas précédent/suivant ;
- annulation réelle des requêtes obsolètes ;
- tests sur manifests volumineux.

## 15. API Elisp minimale

```elisp
(xiiif-open URL)
(xiiif-open-manifest URL)
(xiiif-open-canvas CANVAS)
(xiiif-search-ocr QUERY)
(xiiif-select-region ...)
(xiiif-export-content-state ...)
(xiiif-create-annotation ...)
(xiiif-open-external-viewer ...)
(xiiif-open-locus-artifact ID)
```

Toutes les fonctions réseau ont une variante asynchrone ou retournent une promesse/callback abstrait cohérent avec le package.

## 16. Tests

ERT/unit : parser, normalisation, Content State, ALTO, annotations, cache. Intégration : fixtures IIIF 2/3, erreurs HTTP, redirections, gros manifests. Sécurité : XXE, path traversal, URLs internes, SVG hostile. Interop : bundles agentiques standards et Locus artifact refs.

## 17. Critères d’acceptation

- ouverture fluide de manifests/collections 2/3 ;
- navigation canvas/range ;
- OCR et régions ;
- annotations + Content State valides ;
- Mirador/OpenSeadragon ouvrables sans bricolage manuel ;
- artefact IIIF Canterel ouvert et vérifié par hash ;
- fonctionnement standalone complet ;
- absence de dépendance à Locus Solus/Canterel ;
- aucun code agentique/headless obligatoire dans xiiif.

## 18. Migration depuis le dépôt actuel

Préserver API asynchrone, scheduler, caches, parser, images, regions, anchors, annotations, OCR, Search, Org, batch et citations existants. Retirer de la roadmap toute obligation de devenir un serveur MCP/worker si elle n’est pas utile au viewer humain. Un petit export JSON stable peut rester pour interopérabilité, sans transformer le paquet en service.

## 19. Intégration détaillée des artefacts Locus

Lorsqu’un artefact possède `viewer_hint: iiif`, xiiif reçoit une référence structurée contenant au minimum l’ID Locus, le media type, les hashes attendus et l’un des locators suivants : manifest URL, canvas ID, Content State, annotation target ou snapshot local. xiiif affiche toujours séparément :

- l’identité canonique de l’artefact Locus ;
- la ressource distante live ;
- le snapshot utilisé pendant le run ;
- l’état d’intégrité ;
- les divergences de métadonnées ou de contenu.

Une ressource distante modifiée après le run ne doit jamais faire croire que la preuve historique a changé. Le snapshot/hash reste la référence de reproduction ; la ressource live sert à constater l’évolution.

## 20. Comparaison et revue humaine

Le viewer doit permettre une revue confortable des productions agentiques :

- juxtaposer original et dérivé ;
- superposer la région revendiquée ;
- afficher OCR source/correction et contexte ;
- ouvrir le rapport interprétatif sans l’injecter dans le rendu de la source ;
- enregistrer `accept`, `needs-correction`, `wrong-target`, `source-changed` ou commentaire libre via Locus lorsque connecté.

Cette revue n’est pas une validation scientifique complète. Elle produit un finding humain attachable à un ReviewDossier.

## 21. Mirador et OpenSeadragon

L’intégration externe doit être de première classe, pas un simple copier-coller d’URL. xiiif peut générer une petite page/URL locale ou Locus contenant la configuration du viewer et le Content State courant. Le round-trip souhaité est :

```text
xiiif → ouvrir viewer → navigation/sélection → récupérer Content State → xiiif
```

Lorsque le retour automatique n’est pas techniquement disponible, l’export/import Content State doit suffire. Aucun plugin propriétaire n’est requis.

## 22. Édition et écriture distante

Par défaut, les annotations sont locales ou staging Locus. L’écriture vers un serveur d’annotations externe n’est activée que pour un endpoint explicitement configuré, avec auth-source, confirmation et journal de réponse. xiiif ne doit jamais supposer que le manifest lui-même est modifiable.

## 23. Accessibilité et clavier

Toutes les fonctions principales doivent être utilisables au clavier : navigation canvas/range, recherche OCR, sélection numérique de région, ouverture du viewer externe, copie de Content State, création d’annotation. Les previews graphiques ne doivent pas être la seule manière de connaître les coordonnées ou la cible.

## 24. Documentation et exemples

Le dépôt doit fournir :

- guide rapide ;
- exemples Gallica et au moins deux autres implémentations IIIF ;
- documentation du modèle Content State ;
- dépannage auth/cache/image services ;
- exemple d’ouverture d’un artifact bundle Canterel/Locus ;
- table de compatibilité IIIF 2/3.
