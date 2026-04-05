# mono – Monorepo CLI

Ein leichtgewichtiges Monorepo-Tooling, das ausschließlich auf Bash und Standard-Unix-Tools basiert. Kein Python, kein Node, kein jq – nur POSIX-kompatible Bordmittel + Git.

## Installation

**In einem bestehenden Projekt:**

```bash
curl -fsSL https://github.com/codelabrx/monorepo/blob/main/install.sh | bash
```

**Bestimmte Version installieren:**

```bash
curl -fsSL https://github.com/codelabrx/monorepo/blob/main/install.sh | bash -s -- v1.0.0
```

**In ein anderes Verzeichnis:**

```bash
curl -fsSL https://github.com/codelabrx/monorepo/blob/main/install.sh | bash -s -- --dir /path/to/project
```

## Update

```bash
./mono update                         # Auf neueste Version aktualisieren
./mono update --check                 # Nur prüfen ob ein Update verfügbar ist
./mono update --version v1.2.0        # Bestimmte Version installieren
./mono update --list                  # Verfügbare Versionen anzeigen
```

Die aktuelle Version steht in `.mono/VERSION`. Beim Update werden `bin/`, `lib/`, `commands/` und `templates/` ersetzt – der Cache und eigene Konfigurationen bleiben erhalten.

## Was wird installiert?

Der Installer richtet folgende Struktur im Zielverzeichnis ein:

```
├── mono              # CLI Wrapper
├── package.json      # Workspace-Konfiguration (apps/*, libs/*)
├── bunfig.toml       # Bun-Konfiguration
├── apps/             # Alle Applikationen
├── libs/             # Gemeinsam genutzte Bibliotheken
├── .github/workflows/  # CI/CD Workflows (checks, deploy)
└── .mono/
    ├── VERSION       # Aktuelle CLI-Version
    ├── bin/mono      # CLI Entry-Script
    ├── commands/     # Einzelne Commands (*.sh)
    ├── lib/          # Shared Libraries (graph.sh, cache.sh)
    ├── templates/    # Projekt-Templates (app/, lib/)
    ├── workflows/    # Workflow-Quellen (werden nach .github/ kopiert)
    └── cache/        # Task-Cache (automatisch verwaltet)
```

## CLI

```bash
./mono <command> [optionen]
```

### Verfügbare Befehle

| Command | Beschreibung |
|---------|-------------|
| `run` | Führt Targets aus der project.json eines Projekts aus |
| `run-many` | Führt ein Target über mehrere Projekte aus |
| `affected` | Führt ein Target nur in geänderten Projekten aus |
| `graph` | Zeigt den Dependency-Graph aller Projekte |
| `generate` | Generiert neue Apps oder Libs aus Templates |
| `changed` | Zeigt geänderte Apps/Libs seit dem letzten Deploy |
| `deploy-mark` | Setzt den Deploy-Tag auf den aktuellen Commit |
| `cache` | Cache-Verwaltung (Statistik, auflisten, löschen) |
| `update` | CLI auf die neueste Version aktualisieren |
| `help` | Zeigt alle verfügbaren Commands |

---

## project.json

Jedes Projekt (App/Lib) enthält eine `project.json`, die als Projekt-Marker, Target- und Deploy-Konfiguration dient:

```json
{
  "name": "my-app",
  "type": "app",
  "path": "apps/my-app",
  "targets": {
    "install": {
      "command": "bun install"
    },
    "dev": {
      "command": "bun run --watch src/index.ts",
      "dependsOn": ["install"]
    },
    "build": {
      "command": "bun build src/index.ts --outdir dist",
      "dependsOn": ["install"],
      "outputs": ["dist/**"]
    },
    "test": {
      "command": "bun test",
      "dependsOn": ["install"],
      "cache": false
    }
  },
  "deploy": {
    "strategy": "bun",
    "entrypoint": "src/index.ts"
  },
  "dependencies": ["shared-utils"]
}
```

| Feld | Beschreibung |
|------|-------------|
| `name` | Projektname |
| `type` | `app` oder `lib` |
| `path` | Relativer Pfad im Monorepo |
| `targets` | Ausführbare Befehle |
| `targets.<name>.command` | Der CLI-Befehl, der ausgeführt wird |
| `targets.<name>.dependsOn` | Targets, die vorher ausgeführt werden müssen |
| `targets.<name>.outputs` | Output-Pfade für Caching (z.B. `["dist/**"]`) |
| `targets.<name>.cache` | `false` um Caching für dieses Target zu deaktivieren |
| `deploy` | Deploy-Konfiguration |
| `dependencies` | Lib-Abhängigkeiten (optional, zusätzlich zur Auto-Detection) |

---

## Commands

### `run`

Führt Targets aus der `project.json` eines Projekts aus. Löst dabei automatisch die `dependsOn`-Kette und Cross-Project Dependencies auf.

```bash
./mono run my-app:dev                 # Führt 'dev' aus (inkl. dependsOn-Kette)
./mono run my-app:build               # Führt 'build' aus (inkl. install)
./mono run my-app:start --skip-deps   # Nur start, ohne dependsOn
./mono run my-app:build --skip-project-deps  # Ohne Cross-Project Deps
./mono run my-app:build --no-cache    # Caching deaktivieren
./mono run my-app:build --dry-run     # Zeigt Ausführungsplan
./mono run my-app --list              # Alle Targets auflisten
./mono run my-app                     # Alle Targets auflisten (Kurzform)
```

Projekte können über ihren **Namen** oder **Pfad** referenziert werden:

```bash
./mono run my-app:dev                 # Über project.json "name"
./mono run backend/my-api:dev         # Über Pfad unter apps/ oder libs/
```

### `run-many`

Führt ein Target über mehrere Projekte in **topologischer Reihenfolge** aus (Dependencies zuerst).

```bash
./mono run-many --target build                      # Alle Projekte
./mono run-many --target test --apps                # Nur Apps
./mono run-many --target lint --libs                # Nur Libs
./mono run-many --target build --projects app-a,lib-b  # Bestimmte Projekte
./mono run-many --target build --parallel           # Parallel ausführen
./mono run-many --target test --parallel -j 4       # Max 4 parallel
./mono run-many --target build --dry-run            # Plan anzeigen
./mono run-many --target test --continue-on-error   # Bei Fehler weitermachen
```

| Flag | Beschreibung |
|------|-------------|
| `--target`, `-t` | Target-Name (pflicht) |
| `--projects` | Komma-separierte Projektliste |
| `--apps` | Nur Apps |
| `--libs` | Nur Libs |
| `--parallel` | Unabhängige Projekte parallel ausführen |
| `-j <N>` | Maximale parallele Prozesse |
| `--skip-deps` | dependsOn-Kette überspringen |
| `--no-cache` | Caching deaktivieren |
| `--dry-run` | Ausführungsplan anzeigen |
| `--continue-on-error` | Bei Fehler weitermachen |

### `affected`

Führt ein Target nur in **geänderten** Projekten aus. Erkennt auch transitiv betroffene Projekte (wenn sich eine Lib ändert, werden alle abhängigen Apps einbezogen).

```bash
./mono affected --target test                       # Test für alle geänderten
./mono affected --target build --apps               # Nur geänderte Apps
./mono affected --target lint --ref main~3          # Vergleich mit Git-Ref
./mono affected --target build --parallel           # Parallel ausführen
./mono affected --target test --continue-on-error   # Bei Fehler weitermachen
./mono affected --target build --dry-run            # Plan anzeigen
```

| Flag | Beschreibung |
|------|-------------|
| `--target`, `-t` | Target-Name (pflicht) |
| `--tag <tag>` | Deploy-Tag als Vergleichsbasis (Standard: `deploy/latest`) |
| `--ref <ref>` | Beliebige Git-Ref als Vergleichsbasis |
| `--apps` / `--libs` | Filter auf Typ |
| `--parallel`, `-j` | Parallelisierung |
| `--dry-run` | Zeigt betroffene Projekte als **(geändert)** oder **(transitiv)** |

### `graph`

Zeigt den Dependency-Graph aller Projekte.

```bash
./mono graph                          # Gesamtübersicht mit Baumdarstellung
./mono graph --project my-app         # Details zu einem Projekt
./mono graph --order                  # Topologische Build-Reihenfolge
./mono graph --json                   # JSON-Ausgabe
```

| Flag | Beschreibung |
|------|-------------|
| `--project`, `-p` | Graph für ein einzelnes Projekt |
| `--json` | JSON-Ausgabe (`{ nodes, edges }`) |
| `--order` | Topologische Build-Reihenfolge |

### `generate`

Generiert neue Apps oder Libs aus Templates.

```bash
./mono generate app my-app                        # Interaktive Template-Auswahl
./mono generate app my-app --template bun          # App mit Bun-Template
./mono generate app backend/my-api --template bun  # Verschachtelter Pfad
./mono generate lib shared-utils --template bun    # Neue Lib erstellen
./mono generate lib shared/config --template minimal
```

**Name-Format:**
- `app-name` → `apps/app-name/`
- `subfolder/app-name` → `apps/subfolder/app-name/`

**Verfügbare Templates:**

| Template | Beschreibung |
|----------|-------------|
| `empty` | Leeres Verzeichnis |
| `minimal` | Nur README.md |
| `bun` | Bun-Projekt mit TypeScript |

Wird kein `--template` angegeben, erfolgt eine interaktive Auswahl.

**Template-Variablen:**

| Variable | App-Templates | Lib-Templates |
|----------|--------------|--------------|
| `{{APP_NAME}}` / `{{LIB_NAME}}` | Basename | Basename |
| `{{APP_PATH}}` / `{{LIB_PATH}}` | Vollständiger Pfad | Vollständiger Pfad |

**Eigene Templates erstellen:** Neuen Ordner unter `.mono/templates/app/<name>/` oder `.mono/templates/lib/<name>/` anlegen. Dateien können die obigen Platzhalter verwenden. Eine `.template`-Datei (Zeile 1 = Beschreibung, `init: <command>` = Post-Init-Befehl) wird als Metadatei genutzt und nicht kopiert.

### `changed`

Erkennt welche Apps und Libs sich seit dem letzten Deploy geändert haben.

```bash
./mono changed                        # Alle Änderungen seit deploy/latest
./mono changed --apps                 # Nur geänderte Apps
./mono changed --libs                 # Nur geänderte Libs
./mono changed --json                 # JSON-Ausgabe für CI/CD
./mono changed --quiet                # Nur Pfade (eine pro Zeile)
./mono changed --ref main~5           # Vergleich mit beliebiger Git-Ref
```

Die JSON-Ausgabe (`--json`) enthält die Deploy-Konfiguration:

```json
{
  "base": "a4007f0",
  "head": "c6ba265",
  "changed": [
    {
      "path": "apps/my-api",
      "name": "my-api",
      "type": "app",
      "deploy": { "strategy": "bun" }
    }
  ]
}
```

### `deploy-mark`

Markiert den aktuellen Commit als letzten Deploy-Stand.

```bash
./mono deploy-mark                    # Setzt deploy/latest auf HEAD
./mono deploy-mark --push             # Setzt Tag und pusht zum Remote
./mono deploy-mark --tag deploy/prod  # Eigener Tag-Name
```

### `cache`

Verwaltet den Task-Cache.

```bash
./mono cache stats                    # Anzahl Einträge und Größe
./mono cache list                     # Alle gecachten Targets auflisten
./mono cache clear                    # Gesamten Cache löschen
```

---

## Dependency-Graph

mono erkennt Abhängigkeiten zwischen Projekten auf zwei Wegen:

1. **Manuell** – `"dependencies": ["lib-a"]` in der `project.json`
2. **Auto-Detection** – Scannt `.ts/.tsx/.js/.jsx` Dateien nach `@libs/`-Imports

```typescript
import { helper } from "@libs/shared-utils/helper";  // → Dependency auf shared-utils
```

Beide Quellen werden automatisch gemergt und dedupliziert. Die Auto-Detection ignoriert `node_modules/`, `dist/`, `.cache/` und ähnliche Verzeichnisse.

Der Graph wird genutzt für:
- **Topologische Sortierung** – Dependencies werden immer zuerst ausgeführt
- **Transitive Erkennung** – `affected` erkennt, wenn eine Lib-Änderung Apps betrifft
- **Parallele Batches** – unabhängige Projekte können gleichzeitig ausgeführt werden

## Caching

mono cached Target-Ergebnisse automatisch basierend auf einem Hash aus:
- Dateien im Projektverzeichnis (ohne `node_modules`, `dist`, `.git`, etc.)
- Command-String
- Hashes der Cross-Project Dependencies

```json
"build": {
  "command": "bun build src/index.ts --outdir dist",
  "outputs": ["dist/**"]
}
```

Mit `"outputs"` definierte Verzeichnisse werden im Cache gespeichert und bei Cache-Hit wiederhergestellt.

**Caching deaktivieren:**
- Pro Target: `"cache": false` in der `project.json`
- Pro Aufruf: `--no-cache` Flag

Cache-Speicherort: `.mono/cache/`

## CI/CD Workflows

mono liefert GitHub Actions Workflows mit, die bei Installation und Update automatisch nach `.github/workflows/` kopiert werden.

### Checks (`checks.yml`)

Läuft bei Pull Requests und Pushes auf `main`. Führt `mono affected --target test` aus – nur betroffene Projekte werden getestet.

### Deploy (`deploy.yml`)

Läuft bei Pushes auf `main`. Der Workflow hat drei Schritte:

1. **Affected Apps ermitteln** – `mono changed --json --apps` liefert alle geänderten Apps
2. **Deploy pro App** – Für jede geänderte App wird parallel ein Job gestartet:
   - `mono run <app>:deploy` führt das `deploy`-Target aus
   - Bei `"strategy": "docker"` wird anschließend ein Docker Image gebaut und gepusht
3. **Deploy markieren** – `mono deploy-mark --push` setzt den `deploy/latest` Tag

Die Deploy-Strategie wird über `deploy.strategy` in der `project.json` gesteuert:

| Strategy | Verhalten |
|----------|----------|
| `docker` | `deploy`-Target ausführen, dann Docker Image bauen & in die Container Registry pushen |
| `bun` / andere | Nur `deploy`-Target ausführen, kein Docker Build |
| `none` | Kein Deploy |

**Beispiel mit Docker:**

```json
{
  "name": "my-api",
  "type": "app",
  "targets": {
    "deploy": {
      "command": "bun build src/index.ts --outdir dist",
      "dependsOn": ["install"]
    }
  },
  "deploy": {
    "strategy": "docker"
  }
}
```

Das `deploy`-Target baut die App (z.B. nach `dist/`), danach wird das `Dockerfile` im App-Verzeichnis genutzt, um das Image zu bauen. Das Image wird unter `ghcr.io/<owner>/<repo>/<app-name>` mit den Tags `latest` und dem Git-SHA veröffentlicht.

**Beispiel ohne Docker:**

```json
{
  "name": "my-frontend",
  "type": "app",
  "targets": {
    "deploy": {
      "command": "bun run build && cp -R dist/ /output/",
      "dependsOn": ["install"]
    }
  },
  "deploy": {
    "strategy": "static"
  }
}
```

Hier wird nur das `deploy`-Target ausgeführt – ohne Docker Build.

**Registry anpassen:** Die `REGISTRY` Variable im Workflow kann geändert werden, um z.B. AWS ECR oder eine andere Registry zu verwenden.

## Voraussetzungen

- **Bash** (3.2+, auf macOS vorinstalliert)
- **Git**
- Standard-Unix-Tools (`grep`, `sed`, `find`, `shasum`, `curl`, ...)

## Eigene Commands erstellen

Erstelle eine neue Datei unter `.mono/commands/<name>.sh`:

```bash
#!/usr/bin/env bash
# description: Kurze Beschreibung des Commands

echo "Mein neuer Command"
```

Der Command ist sofort über `mono <name>` aufrufbar. Die `# description:`-Zeile erscheint in `mono help`.

Die erste Zeile mit `# description:` wird automatisch in `mono help` angezeigt.

Im Command stehen folgende Variablen zur Verfügung:

- `MONO_ROOT` – Absoluter Pfad zum Repository-Root
- `MONO_DIR` – Absoluter Pfad zu `.mono/`

## Schnellstart

```bash
# 1. Neues Projekt anlegen
mkdir my-project && cd my-project
git init

# 2. mono CLI installieren
curl -fsSL https://raw.githubusercontent.com/codelabrx/monorepo/main/install.sh | bash

# 3. Erste App erstellen
./mono generate app my-api --template bun

# 4. App starten
./mono run my-api:dev
```

3. CLI ausführbar machen:
   ```bash
   chmod +x mono
   ```

4. Apps und Libs nach Bedarf anlegen:
   ```bash
   mkdir -p apps/<app-name>
   mkdir -p libs/<lib-name>
   ```

