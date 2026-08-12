# Plan de migration xiiif

1. Geler les APIs publiques réellement utilisées aujourd’hui et les couvrir par ERT.
2. Conserver parser, scheduler async, cache, image, regions, anchors, annotations, OCR, Search, Org et batch.
3. Retirer des objectifs obligatoires toute dépendance à Canterel/Locus ou tout serveur MCP générique.
4. Ajouter un `ArtifactRef` minimal et un adapter optionnel `locusolus-xiiif` côté client Emacs.
5. Renforcer Content State, snapshots/hash display et comparaison live/historique.
6. Ajouter bridge Mirador/OpenSeadragon avec round-trip Content State lorsque possible.
7. Ajouter fixtures de bundles produits par agents et tests de sécurité.
8. Mettre à jour README pour présenter xiiif comme workbench humain autonome.
