#!/usr/bin/env bash
set -euo pipefail

# ─── mono CLI Installer ────────────────────────────────────────────────────
#
# Verwendung:
#   curl -fsSL https://raw.githubusercontent.com/codelabrx/mono/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/codelabrx/mono/main/install.sh | bash -s -- v1.0.0
#   curl -fsSL https://raw.githubusercontent.com/codelabrx/mono/main/install.sh | bash -s -- --dir /path/to/project
#
# Was passiert:
#   1. Lädt die angegebene (oder neueste) Version von GitHub herunter
#   2. Installiert .mono/ und den mono Wrapper im Zielverzeichnis
#   3. Fertig – mono ist sofort einsatzbereit
#

MONO_REPO="codelabrx/mono"

# ─── Farben ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[mono]${NC} $*"; }
warn()  { echo -e "${YELLOW}[mono]${NC} $*" >&2; }
error() { echo -e "${RED}[mono]${NC} $*" >&2; }

# ─── Voraussetzungen prüfen ────────────────────────────────────────────────
check_deps() {
  local missing=()

  for cmd in curl tar git bash; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Fehlende Abhängigkeiten: ${BOLD}${missing[*]}${NC}"
    exit 1
  fi
}

# ─── Neueste Version ermitteln ─────────────────────────────────────────────
latest_version() {
  curl -fsSL "https://api.github.com/repos/${MONO_REPO}/tags?per_page=1" 2>/dev/null \
    | grep '"name"' \
    | head -1 \
    | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# ─── Installation ──────────────────────────────────────────────────────────
install() {
  local version="${1:-}"
  local target_dir="${2:-.}"

  # Absoluten Pfad ermitteln
  target_dir="$(cd "${target_dir}" && pwd)"

  # Version bestimmen
  if [[ -z "${version}" ]]; then
    log "Ermittle neueste Version..."
    version="$(latest_version)"
    if [[ -z "${version}" ]]; then
      error "Konnte neueste Version nicht ermitteln"
      error "Prüfe deine Internetverbindung und ob ${BOLD}${MONO_REPO}${NC} existiert"
      exit 1
    fi
  fi

  log "Installiere mono CLI ${BOLD}${version}${NC} in ${BOLD}${target_dir}${NC}"

  # Prüfen ob bereits installiert
  if [[ -d "${target_dir}/.mono" ]]; then
    local current="unknown"
    if [[ -f "${target_dir}/.mono/VERSION" ]]; then
      current="$(tr -d '[:space:]' < "${target_dir}/.mono/VERSION")"
    fi
    warn "mono CLI ist bereits installiert (Version: ${BOLD}${current}${NC})"
    warn "Verwende ${CYAN}mono update${NC} zum Aktualisieren"
    exit 0
  fi

  # Temporäres Verzeichnis
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '${tmp_dir}'" EXIT

  # Tarball herunterladen
  local tarball_url="https://github.com/${MONO_REPO}/archive/refs/tags/${version}.tar.gz"
  log "Lade ${BOLD}${version}${NC} herunter..."

  if ! curl -fsSL "${tarball_url}" -o "${tmp_dir}/mono.tar.gz" 2>/dev/null; then
    error "Download fehlgeschlagen"
    error "Version ${BOLD}${version}${NC} existiert möglicherweise nicht"
    exit 1
  fi

  # Entpacken
  if ! tar -xzf "${tmp_dir}/mono.tar.gz" -C "${tmp_dir}" 2>/dev/null; then
    error "Entpacken fehlgeschlagen"
    exit 1
  fi

  # Extrahiertes Verzeichnis finden
  local extracted_dir
  extracted_dir="$(find "${tmp_dir}" -maxdepth 1 -type d -name 'mono-*' | head -1)"

  if [[ -z "${extracted_dir}" || ! -d "${extracted_dir}/.mono" ]]; then
    error "Ungültiges Archiv: .mono Verzeichnis nicht gefunden"
    exit 1
  fi

  # ─── Dateien kopieren ──────────────────────────────────────────────────
  log "Installiere Dateien..."

  # .mono Verzeichnis
  cp -R "${extracted_dir}/.mono" "${target_dir}/.mono"

  # mono Wrapper
  if [[ -f "${extracted_dir}/mono" ]]; then
    cp "${extracted_dir}/mono" "${target_dir}/mono"
    chmod +x "${target_dir}/mono"
  fi

  # Berechtigungen
  chmod +x "${target_dir}/.mono/bin/mono"

  # Cache-Verzeichnis erstellen
  mkdir -p "${target_dir}/.mono/cache"

  # GitHub Workflows installieren
  if [[ -d "${target_dir}/.mono/workflows" ]]; then
    mkdir -p "${target_dir}/.github/workflows"
    for wf in "${target_dir}/.mono/workflows/"*.yml; do
      [[ -f "${wf}" ]] || continue
      cp "${wf}" "${target_dir}/.github/workflows/"
    done
    log "GitHub Workflows installiert"
  fi

  # ─── Basis-Dateien erstellen (falls nicht vorhanden) ────────────────────
  mkdir -p "${target_dir}/apps" "${target_dir}/libs"

  # package.json (Bun/Node Workspaces)
  if [[ ! -f "${target_dir}/package.json" ]]; then
    local project_name
    project_name="$(basename "${target_dir}")"
    cat > "${target_dir}/package.json" << EOF
{
  "name": "${project_name}",
  "private": true,
  "workspaces": [
    "apps/*",
    "libs/*"
  ]
}
EOF
    log "package.json erstellt"
  fi

  # bunfig.toml
  if [[ ! -f "${target_dir}/bunfig.toml" ]]; then
    cat > "${target_dir}/bunfig.toml" << 'EOF'
[install]
linker = "hoisted"
linkWorkspacePackages = true
EOF
    log "bunfig.toml erstellt"
  fi

  # .gitignore
  if [[ ! -f "${target_dir}/.gitignore" ]]; then
    cat > "${target_dir}/.gitignore" << 'EOF'
# dependencies (bun install)
node_modules

# lockfiles in Unterprojekten (Root bun.lock wird committed)
apps/*/bun.lock
apps/*/bun.lockb
libs/*/bun.lock
libs/*/bun.lockb

# output
out
dist
*.tgz

# code coverage
coverage
*.lcov

# logs
logs
*.log
report.[0-9]*.[0-9]*.[0-9]*.[0-9]*.json

# dotenv environment variable files
.env
.env.development.local
.env.test.local
.env.production.local
.env.local

# caches
.eslintcache
.cache
*.tsbuildinfo
.mono/cache

# IntelliJ based IDEs
.idea

# Finder (macOS)
.DS_Store
EOF
    log ".gitignore erstellt"
  fi

  echo ""
  log "Installation abgeschlossen!"
  echo ""
  echo -e "  ${BOLD}Erste Schritte:${NC}"
  echo -e "    cd ${target_dir}"
  echo -e "    ./mono help"
  echo ""
  echo -e "  ${BOLD}Updates:${NC}"
  echo -e "    ./mono update --check"
  echo -e "    ./mono update"
  echo ""
}

# ─── Argumente parsen ──────────────────────────────────────────────────────
main() {
  local version=""
  local target_dir="."

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)
        target_dir="${2:-.}"
        shift 2
        ;;
      --help|-h)
        echo ""
        echo -e "${BOLD}mono CLI Installer${NC}"
        echo ""
        echo -e "${BOLD}Verwendung:${NC}"
        echo "  curl -fsSL https://raw.githubusercontent.com/${MONO_REPO}/main/install.sh | bash"
        echo "  curl -fsSL ... | bash -s -- <version>"
        echo "  curl -fsSL ... | bash -s -- --dir /path/to/project"
        echo ""
        echo -e "${BOLD}Optionen:${NC}"
        echo "  <version>           Version installieren (z.B. v1.0.0)"
        echo "  --dir <pfad>        Zielverzeichnis (Standard: aktuelles Verzeichnis)"
        echo "  --help, -h          Diese Hilfe anzeigen"
        echo ""
        exit 0
        ;;
      v*)
        version="$1"
        shift
        ;;
      *)
        error "Unbekannte Option: $1"
        exit 1
        ;;
    esac
  done

  check_deps
  install "${version}" "${target_dir}"
}

main "$@"
