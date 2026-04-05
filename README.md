# Monorepo Template

Ein Template-Repository zur Initialisierung neuer Monorepos.

## Struktur

```
├── mono           # CLI Wrapper (leitet an .mono/bin/mono weiter)
├── apps/          # Alle Applikationen
├── libs/          # Gemeinsam genutzte Bibliotheken
└── .mono/         # Scripts zur Verwaltung des Monorepos
```

### `apps/`

Enthält alle eigenständigen Applikationen. Jede App lebt in einem eigenen Unterverzeichnis und kann unabhängig gebaut und deployed werden.

### `libs/`

Enthält wiederverwendbare Bibliotheken und Pakete, die von mehreren Apps geteilt werden.

### `.mono/`

Enthält Scripts und Konfigurationen zur Verwaltung des Monorepos (z. B. Build-Orchestrierung, Dependency-Management, CI/CD-Hilfsskripte).

```
.mono/
├── bin/
│   └── mono           # CLI Entry-Script
└── commands/
    └── <name>.sh      # Einzelne Commands
```

## CLI (`mono`)

Das Monorepo wird über das CLI-Tool `mono` verwaltet.

### Aufruf

```bash
./mono <command> [optionen]
```

### Verfügbare Befehle

| Command | Beschreibung |
|---------|-------------|
| `help`  | Zeigt alle verfügbaren Commands |
| `generate app <name>` | Erstellt eine neue App aus einem Template |
| `hello` | Beispiel-Command |

### `generate app`

Erstellt eine neue App im `apps/`-Verzeichnis aus einem Template.

```bash
./mono generate app <name> [--template <template>]
```

**Name-Format:**
- `app-name` → `apps/app-name/`
- `subfolder/app-name` → `apps/subfolder/app-name/`

**Verfügbare Templates:**

| Template | Beschreibung |
|----------|-------------|
| `empty`  | Leeres Verzeichnis |
| `minimal`| Nur README.md |
| `bun`   | Bun-Projekt mit TypeScript |

Wird kein `--template` angegeben, erfolgt eine interaktive Auswahl.

**Eigene Templates erstellen:** Neuen Ordner unter `.mono/templates/app/<name>/` anlegen. Dateien können die Platzhalter `{{APP_NAME}}` und `{{APP_PATH}}` verwenden. Eine `.template`-Datei (erste Zeile = Beschreibung) wird als Metadatei genutzt und nicht kopiert.

### Neuen Command erstellen

Erstelle eine neue Datei unter `.mono/commands/<name>.sh`:

```bash
#!/usr/bin/env bash
# description: Kurze Beschreibung des Commands

echo "Mein neuer Command"
```

Die erste Zeile mit `# description:` wird automatisch in `mono help` angezeigt.

Im Command stehen folgende Variablen zur Verfügung:

- `MONO_ROOT` – Absoluter Pfad zum Repository-Root
- `MONO_DIR` – Absoluter Pfad zu `.mono/`

## Verwendung

1. Repository als Template nutzen oder klonen:
   ```bash
   git clone https://github.com/codelabrx/monorepo.git <projekt-name>
   cd <projekt-name>
   ```

2. Remote auf das neue Repository setzen:
   ```bash
   git remote set-url origin <neue-repo-url>
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

