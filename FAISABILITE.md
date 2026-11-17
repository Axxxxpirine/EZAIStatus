# EZAIStatus — notes techniques des connecteurs

Constats faits en lecture seule sur macOS 27 (arm64), sans modifier aucune app, avec ChatGPT/Codex 26.1106
(`com.openai.codex`) et Claude 5.11492 (`com.anthropic.claudefordesktop`).

**Aucune de ces apps ne publie d'API ou d'événement documenté pour ces états.** Tout repose sur leurs fichiers internes,
qui peuvent changer à chaque mise à jour. D'où : un connecteur isolé par app, une vérification du schéma au démarrage,
et l'indicateur « source illisible » plutôt qu'un faux zéro.

## Matrice

| Critère | Codex (app ChatGPT) | Claude Code (app Claude) |
|---|---|---|
| Source | `~/.codex/state_5.sqlite` + rollouts `.jsonl` | `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json` + `~/.claude/projects/**/*.jsonl` |
| Identifiant stable | `threads.id` | `sessionId` (`local_…`) |
| Titre | `name` / `title` | `title` |
| Sous-agents exclus des compteurs | `thread_source = 'subagent'` | fichiers à part (`subagents/`) |
| En cours | dernier `task_started` sans `task_complete` | dernière entrée de la transcription sans `end_turn` (`lastTurnEdgeAt` bouge aussi quand l'agent pose une question en cours de tour : pas fiable seul) |
| Attend ta réponse | `request_user_input` sans réponse ; les demandes d'approbation de commandes ne sont pas écrites sur disque | `AskUserQuestion` / `ExitPlanMode` sans réponse, `turnWrapUp.needsUser` ; autorisations d'outil via le hook facultatif |
| Fin de réponse | `task_complete` | `end_turn` dans la transcription |
| Consultation | native : `thread_read_receipts.first_unread_turn` | `lastFocusedAt` postérieur à la fin du tour |
| Ouverture directe | `codex://threads/<id>` | `claude://code/continue?session=<id>` |
| Permissions macOS | aucune (app hors bac à sable) | aucune |
| Résistance aux mises à jour | moyenne (schéma SQLite versionné `state_5`) | moyenne (champs internes du desktop) |

## Sources écartées

- **Claude Chat** : la conversation ne vit que dans la page claude.ai de l'app, rien n'est écrit sur le Mac. Les seules voies
  (lire la fenêtre par l'Accessibilité, appeler l'API privée avec les cookies de l'app) sont fragiles ou contraires aux conditions.
- **Claude Cowork** exécuté dans le cloud : seule une empreinte chiffrée reste en local, sans titre ni état.
- **Grok Bot** : attente et fin non lue sont lisibles dans son cache, mais ni l'état « en cours » ni l'ouverture d'un bot précis.

## Conséquences techniques

- Distribution hors Mac App Store (le bac à sable interdit de lire les dossiers des autres apps) : Developer ID + notarisation.
- Surveillance par FSEvents filtrée sur les fichiers utiles (aucun sondage) + minuterie de secours à 60 s, lecture incrémentale
  des fins de fichiers, SQLite en lecture seule.
- macOS 14 minimum (Observation), Apple Silicon et Intel (binaire universel).
- Stockage local : acquittements et dernières transitions dans `~/Library/Application Support/EZAIStatus/`.

## Sous-agents et projets

- Codex : `thread_spawn_edges` relie parent et enfant ; titre = `agent_nickname` + dernier élément d'`agent_path` ; état par le rollout
  de l'enfant. Projet = `projects.name` si `project_id`, sinon dernier dossier de `cwd` ; rien pour les dossiers datés
  `~/Documents/Codex/AAAA-MM-JJ/…` des conversations sans projet.
- Claude Code : `~/.claude/projects/<dossier>/<cliSessionId>/subagents/agent-<id>.jsonl` (+ `.meta.json` : `description`, `finished`).
  Toutes les entrées y sont `isSidechain`. Projet = dernier dossier d'`originCwd`, dépôt d'origine pour une worktree `.claude/worktrees`.
- Affichage : en retrait sous leur conversation, seulement actifs ou terminés depuis le dernier message de l'utilisateur, 6 au plus,
  jamais comptés. Une conversation consultée dont un sous-agent travaille encore reste « en cours ».
- Icônes : celles des apps installées, lues au moment de l'affichage (rien n'est embarqué) ; pour Codex,
  `icon-codex-light.png` / `icon-codex-dark-color.png` de l'app ChatGPT selon l'apparence. Badge texte en secours.

## Commandes en arrière-plan de Claude Code

- Chaque commande écrit dans `/private/tmp/claude-<uid>/<dossier>/<cliSessionId>/tasks/<id>.output` (premier plan compris).
  Une commande vit tant que son shell enveloppe tient ce fichier ouvert : lu par `libproc` sur les seuls shells (~1 ms ; `lsof` : 0,4 s).
- Passage en arrière-plan annoncé dans un `tool_result` : « running in background with ID: … » ou « moved to the background (ID: …) ».
  La fin arrive en `<task-notification>`. Description = `description` de l'appel Bash, retrouvée par un index incrémental.
- Une commande lancée par un sous-agent peut lui survivre longtemps : elle reste affichée tant que son processus vit.
- Affichage : sous la conversation, icône de terminal, ancienneté au-delà de 10 min.

## Mesures

- Balayage complet à chaud : ~17 ms. `FileManager.attributesOfItem` lisait les attributs étendus et coûtait 30 ms de plus :
  remplacé par `stat()`.
- App en marche avec plusieurs agents actifs : ~1 % d'un cœur en moyenne, 20 à 30 Mo d'empreinte mémoire.

## Ouverture directe

- Codex : `codex://threads/<id>` ouvre le fil et Codex le marque lu aussitôt (`first_unread_turn` vidé).
- Claude Code : `claude://code/continue?session=<id>` ouvre la session et met à jour `lastFocusedAt`.
  Piège : `claude://code/needs-input?session=<id>` n'ouvre la session que si Claude la considère déjà en attente.

## Hook Claude Code (facultatif)

- Les sessions du desktop appellent les hooks de `~/.claude/settings.json`, y compris celles déjà ouvertes.
- Une demande d'autorisation produit `Notification` / `permission_prompt` environ 6 s après la demande ; autorisée plus vite,
  elle ne produit rien. `PostToolUse` ou `Stop` suivent la décision.
- Le script ne note que la session, le type d'événement et le type de notification (extraits avec `plutil`), pour que le journal
  reste minuscule. Horodatage à la seconde : tolérance d'une seconde face au dernier message de l'utilisateur.

## Reste à valider

- Une fin de tour pendant que la session Claude Code est affichée (`lastFocusedAt` peut rester antérieur → faux « non lu »).

## Distribution

- Signature Developer ID, runtime renforcé, notarisation par le compte connecté dans Xcode (`scripts/notarize-xcode.sh`),
  ticket agrafé. Vérifié en quarantaine simulée : Gatekeeper « Notarized Developer ID ».
- Pièges : 403 « required agreement » tant que les contrats Apple ne sont pas acceptés ; `set -o pipefail` + `| head` ou
  `awk … exit` arrête un script en silence (code 141) ; avec deux certificats Developer ID au même nom, signer par empreinte.

## Mises à jour automatiques (Sparkle)

- Sparkle 2 (paquet Swift officiel), framework embarqué dans `Contents/Frameworks` et signé de l'intérieur vers l'extérieur
  par `scripts/build-app.sh`.
- Inactif tant que `release.env` est vide : il faut l'adresse HTTPS publique de l'appcast et la clé publique EdDSA
  (`.build/artifacts/sparkle/Sparkle/bin/generate_keys`, clé privée dans le trousseau, à sauvegarder avec `generate_keys -x`).
- Sparkle demande l'accord de l'utilisateur avant toute vérification automatique ; réglage et bouton « Rechercher maintenant »
  dans les réglages.
- Publier : `scripts/publish-update.sh` met le zip notarisé versionné et `appcast.xml` signé dans `build/updates/`, à déposer
  dans le dossier de l'adresse du flux. Notes de version facultatives dans `notes/<version>.md`.
- Testé de bout en bout avec une clé jetable et un serveur local : une 0.1.0 a trouvé, vérifié et installé une 0.1.1 à sa fermeture.
- Piège : `SULastCheckTime` est enregistré même quand le flux répond 404, ce qui repousse la vérification suivante de 24 h.
