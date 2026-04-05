# mono – Monorepo CLI

A lightweight monorepo tooling based solely on Bash and standard Unix tools. No Python, no Node, no jq – just POSIX-compliant built-in tools + Git.

> **Note:** This project is developed internally by [codelabrx](https://github.com/codelabrx) and is **not an actively maintained open-source project**. It is freely available under the MIT license but is not maintained or extended for external use cases. Those who wish to adapt it to their own needs are welcome to fork the repository.

## License

This project is licensed under the MIT License.

## Maintenance

This project is provided "as is" without active maintenance.
Pull requests or issues may not be reviewed.

## Installation

**In an existing project:**

```bash
curl -fsSL https://github.com/codelabrx/mono/blob/main/install.sh | bash
```

**Install a specific version:**

```bash
curl -fsSL https://github.com/codelabrx/mono/blob/main/install.sh | bash -s -- v1.0.0
```

**Install to a different directory:**

```bash
curl -fsSL https://github.com/codelabrx/mono/blob/main/install.sh | bash -s -- --dir /path/to/project
```

## Update

```bash
./mono update                         # Update to the latest version
./mono update --check                 # Only check if an update is available
./mono update --version v1.2.0        # Install a specific version
./mono update --list                  # Show available versions
```

The current version is located in `.mono/VERSION`. During the update, `bin/`, `lib/`, `commands/`, and `templates/` are replaced – the cache and custom configurations remain intact.

## What gets installed?

The installer sets up the following structure in the target directory:

```
├── mono              # CLI wrapper
├── package.json      # Workspace configuration (apps/*, libs/*)
├── bunfig.toml       # Bun configuration
├── apps/             # All applications
├── libs/             # Shared libraries
├── .github/workflows/  # CI/CD workflows (checks, deploy)
└── .mono/
    ├── VERSION       # Current CLI version
    ├── bin/mono      # CLI Entry-Script
    ├── commands/     # Single commands (*.sh)
    ├── lib/          # Shared libraries (graph.sh, cache.sh)
    ├── templates/    # Project templates (app/, lib/)
    ├── workflows/    # Workflow sources (copied to .github/)
    └── cache/        # Task cache (automatically managed)
```

## CLI

```bash
./mono <command> [optionen]
```

### Available commands

| Command | Description |
|---------|-------------|
| `run` | Runs targets from the project.json of a project |
| `run-many` | Runs a target over multiple projects |
| `affected` | Runs a target only in changed projects |
| `graph` | Shows the dependency graph of all projects |
| `generate` | Generates new apps or libs from templates |
| `changed` | Shows changed apps/libs since the last deploy |
| `deploy-mark` | Sets the deploy tag on the current commit |
| `cache` | Cache management (statistics, list, clear) |
| `update` | CLI update to the latest version |
| `help` | Shows all available commands |

---

## project.json

Each project (App/Lib) contains a `project.json`, which serves as the project marker, target, and deploy configuration:

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

| Field | Description |
|------|-------------|
| `name` | Project name |
| `type` | `app` or `lib` |
| `path` | Relative path in the monorepo |
| `targets` | Executable commands |
| `targets.<name>.command` | The CLI command that is executed |
| `targets.<name>.dependsOn` | Targets that must be executed before |
| `targets.<name>.outputs` | Output paths for caching (e.g. `["dist/**"]`) |
| `targets.<name>.cache` | `false` to disable caching for this target |
| `deploy` | Deploy configuration |
| `dependencies` | Library dependencies (optional, in addition to auto-detection) |

---

## Commands

### `run`

Runs targets from the `project.json` of a project. Automatically resolves the `dependsOn` chain and cross-project dependencies.

```bash
./mono run my-app:dev                 # Runs 'dev' (including dependsOn chain)
./mono run my-app:build               # Runs 'build' (including install)
./mono run my-app:start --skip-deps   # Only start, without dependsOn
./mono run my-app:build --skip-project-deps  # Without cross-project deps
./mono run my-app:build --no-cache    # Disable caching
./mono run my-app:build --dry-run     # Shows execution plan
./mono run my-app --list              # Lists all targets
./mono run my-app                     # Lists all targets (short form)
```

Projects can be referenced by their **name** or **path**:

```bash
./mono run my-app:dev                 # Over project.json "name"
./mono run backend/my-api:dev         # Over path under apps/ or libs/
```

### `run-many`

Runs a target over multiple projects in **topological order** (dependencies first).

```bash
./mono run-many --target build                      # All projects
./mono run-many --target test --apps                # Only apps
./mono run-many --target lint --libs                # Only libs
./mono run-many --target build --projects app-a,lib-b  # Specific projects
./mono run-many --target build --parallel           # Run in parallel
./mono run-many --target test --parallel -j 4       # Max 4 parallel
./mono run-many --target build --dry-run            # Plan display
./mono run-many --target test --continue-on-error   # Continue on error
```

| Flag | Description |
|------|-------------|
| `--target`, `-t` | Target name (required) |
| `--projects` | Comma-separated project list |
| `--apps` | Only apps |
| `--libs` | Only libs |
| `--parallel` | Run independent projects in parallel |
| `-j <N>` | Maximum parallel processes |
| `--skip-deps` | Skip dependsOn chain |
| `--no-cache` | Disable caching |
| `--dry-run` | Shows execution plan |
| `--continue-on-error` | Continue on error |

### `affected`

Runs a target only in **changed** projects. Detects transitively affected projects (if a lib changes, all dependent apps are included).

```bash
./mono affected --target test                       # Test for all changed
./mono affected --target build --apps               # Only changed apps
./mono affected --target lint --ref main~3          # Comparison with Git ref
./mono affected --target build --parallel           # Run in parallel
./mono affected --target test --continue-on-error   # Continue on error
./mono affected --target build --dry-run            # Plan display
```

| Flag | Description |
|------|-------------|
| `--target`, `-t` | Target name (required) |
| `--tag <tag>` | Deploy tag as comparison basis (default: `deploy/latest`) |
| `--ref <ref>` | Any Git ref as comparison basis |
| `--apps` / `--libs` | Filter on type |
| `--parallel`, `-j` | Parallelization |
| `--dry-run` | Shows affected projects as **(changed)** or **(transitively)** |

### `graph`

Shows the dependency graph of all projects.

```bash
./mono graph                          # Overall view with tree representation
./mono graph --project my-app         # Details for a project
./mono graph --order                  # Topological build order
./mono graph --json                   # JSON output
```

| Flag | Description |
|------|-------------|
| `--project`, `-p` | Graph for a single project |
| `--json` | JSON output (`{ nodes, edges }`) |
| `--order` | Topological build order |

### `generate`

Generates new apps or libs from templates.

```bash
./mono generate app my-app                        # Interactive template selection
./mono generate app my-app --template bun          # App with Bun template
./mono generate app backend/my-api --template bun  # Nested path
./mono generate lib shared-utils --template bun    # New lib
./mono generate lib shared/config --template minimal
```

**Name format:**
- `app-name` → `apps/app-name/`
- `subfolder/app-name` → `apps/subfolder/app-name/`

**Available templates:**

| Template | Description |
|----------|-------------|
| `empty` | Empty directory |
| `minimal` | Only README.md |
| `bun` | Bun project with TypeScript |

If no `--template` is given, an interactive selection is made.

**Template variables:**

| Variable | App templates | Lib templates |
|----------|--------------|--------------|
| `{{APP_NAME}}` / `{{LIB_NAME}}` | Basename | Basename |
| `{{APP_PATH}}` / `{{LIB_PATH}}` | Full path | Full path |

**Create your own templates:** Create a new folder under `.mono/templates/app/<name>/` or `.mono/templates/lib/<name>/`. Files can use the above placeholders. A `.template` file (Line 1 = Description, `init: <command>` = Post-init command) is used as metadata and not copied.

### `changed`

Detects which apps and libs have changed since the last deploy.

```bash
./mono changed                        # All changes since deploy/latest
./mono changed --apps                 # Only changed apps
./mono changed --libs                 # Only changed libs
./mono changed --json                 # JSON output for CI/CD
./mono changed --quiet                # Only paths (one per line)
./mono changed --ref main~5           # Comparison with any Git ref
```

The JSON output (`--json`) contains the deploy configuration:

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

Marks the current commit as the latest deploy.

```bash
./mono deploy-mark                    # Sets deploy/latest on HEAD
./mono deploy-mark --push             # Sets tag and pushes to remote
./mono deploy-mark --tag deploy/prod  # Custom tag name
```

### `cache`

Manages the task cache.

```bash
./mono cache stats                    # Number of entries and size
./mono cache list                     # All cached targets
./mono cache clear                    # Clears the entire cache
```

---

## Dependency Graph

mono detects dependencies between projects on two ways:

1. **Manually** – `"dependencies": ["lib-a"]` in the `project.json`
2. **Auto-detection** – Scans `.ts/.tsx/.js/.jsx` files for `@libs/`-imports

```typescript
import { helper } from "@libs/shared-utils/helper";  // → Dependency on shared-utils
```

Both sources are merged and deduplicated. The auto-detection ignores `node_modules/`, `dist/`, `.cache/` and similar directories.

The graph is used for:
- **Topological sorting** – Dependencies are always executed first
- **Transitive detection** – `affected` detects when a lib change affects apps
- **Parallel batches** – Independent projects can be executed simultaneously

## Caching

mono caches target results automatically based on a hash of:
- Files in the project directory (excluding `node_modules`, `dist`, `.git`, etc.)
- Command string
- Hashes of cross-project dependencies

```json
"build": {
  "command": "bun build src/index.ts --outdir dist",
  "outputs": ["dist/**"]
}
```

With `"outputs"` defined directories are stored in the cache and restored on cache hit.

**Disable caching:**
- Per target: `"cache": false` in the `project.json`
- Per call: `--no-cache` flag

Cache storage: `.mono/cache/`

## CI/CD Workflows

mono provides GitHub Actions workflows that are copied to `.github/workflows/` on installation and update.

### Checks (`checks.yml`)

Runs on Pull Requests and Pushes to `main`. Executes `mono affected --target test` – only affected projects are tested.

### Deploy (`deploy.yml`)

Runs on Pushes to `main`. The workflow has three steps:

1. **Affected apps determined** – `mono changed --json --apps` lists all changed apps
2. **Deploy per app** – For each changed app, a parallel job is started:
   - `mono run <app>:deploy` runs the `deploy` target
   - With `"strategy": "docker"` builds and pushes a Docker image
3. **Deploy mark** – `mono deploy-mark --push` sets the `deploy/latest` tag

The deploy strategy is controlled by `deploy.strategy` in the `project.json`:

| Strategy | Behavior |
|----------|----------|
| `docker` | Run the `deploy` target, then build and push a Docker image |
| `bun` / other | Only run the `deploy` target, no Docker build |
| `none` | No deploy |

**Example with Docker:**

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

The `deploy` target builds the app (e.g. after `dist/`), then uses the `Dockerfile` in the app directory to build the image. The image is published under `ghcr.io/<owner>/<repo>/<app-name>` with tags `latest` and the Git-SHA.

**Example without Docker:**

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

Here, only the `deploy` target is executed – without Docker build.

**Registry customization:** The `REGISTRY` variable in the workflow can be changed to use, e.g., AWS ECR or another registry.

## Prerequisites

- **Bash** (3.2+, installed on macOS)
- **Git**
- Standard Unix tools (`grep`, `sed`, `find`, `shasum`, `curl`, ...)

## Create your own commands

Create a new file under `.mono/commands/<name>.sh`:

```bash
#!/usr/bin/env bash
# description: Short description of the command

echo "My new command"
```

The command is immediately callable as `mono <name>`. The `# description:` line appears in `mono help`.

The first line with `# description:` is automatically displayed in `mono help`.

In the command, the following variables are available:

- `MONO_ROOT` – Absolute path to the repository root
- `MONO_DIR` – Absolute path to `.mono/`

## Quick start

```bash
# 1. Create a new project
mkdir my-project && cd my-project
git init

# 2. Install the mono CLI
curl -fsSL https://raw.githubusercontent.com/codelabrx/monorepo/main/install.sh | bash

# 3. Create the first app
./mono generate app my-api --template bun

# 4. Start the app
./mono run my-api:dev
```

3. Make the CLI executable:
   ```bash
   chmod +x mono
   ```

4. Create apps and libs as needed:
   ```bash
   mkdir -p apps/<app-name>
   mkdir -p libs/<lib-name>
   ```

