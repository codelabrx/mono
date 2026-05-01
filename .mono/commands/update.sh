#!/usr/bin/env bash
# description: mono CLI auf die neueste Version aktualisieren

MONO_REPO="${MONO_UPDATE_REPO:-codelabrx/mono}"
MONO_VERSION_FILE="${MONO_DIR}/VERSION"

# ─── Help ───────────────────────────────────────────────────────────────────
update::help() {
  echo ""
  echo -e "${BOLD}mono update${NC} – CLI aktualisieren"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono update [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --version <tag>              Bestimmte Version installieren (z.B. v1.0.0)"
  echo "  --check                      Nur prüfen ob ein Update verfügbar ist"
  echo "  --list                       Verfügbare Versionen anzeigen"
  echo "  --sync-workflows <prefix>    Geänderte Workflows mit Prefix kopieren"
  echo "  --help, -h                   Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono update                                    # Update auf neueste Version"
  echo "  mono update --check                            # Prüft auf Updates"
  echo "  mono update --version v1.2.0                   # Bestimmte Version installieren"
  echo "  mono update --list                             # Zeigt verfügbare Versionen"
  echo "  mono update --sync-workflows updated.          # Kopiert geänderte Workflows"
  echo "                                                 # als updated.<name>.yml"
  echo ""
  echo -e "${BOLD}Aktuelle Version:${NC}"
  echo "  $(update::current_version)"
  echo ""
}

# ─── Aktuelle Version lesen ────────────────────────────────────────────────
update::current_version() {
  if [[ -f "${MONO_VERSION_FILE}" ]]; then
    tr -d '[:space:]' < "${MONO_VERSION_FILE}"
  else
    echo "unknown"
  fi
}

# ─── Verfügbare Versionen von GitHub laden ─────────────────────────────────
update::fetch_tags() {
  curl -fsSL "https://api.github.com/repos/${MONO_REPO}/tags?per_page=20" 2>/dev/null \
    | grep '"name"' \
    | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | grep '^v'
}

# ─── Neueste Version ermitteln ─────────────────────────────────────────────
update::latest_version() {
  update::fetch_tags | head -1
}

# ─── Versions-Check ───────────────────────────────────────────────────────
update::check() {
  local current
  current="$(update::current_version)"

  mono::log "Aktuelle Version: ${BOLD}${current}${NC}"
  mono::log "Prüfe auf Updates..."

  local latest
  latest="$(update::latest_version)"

  if [[ -z "${latest}" ]]; then
    mono::error "Konnte keine Versionen von GitHub laden"
    mono::warn "Prüfe deine Internetverbindung und ob das Repository ${BOLD}${MONO_REPO}${NC} existiert"
    return 1
  fi

  if [[ "${current}" == "${latest}" || "v${current}" == "${latest}" ]]; then
    mono::log "Du verwendest bereits die neueste Version ${BOLD}${latest}${NC}"
    return 0
  fi

  echo ""
  mono::log "Update verfügbar: ${BOLD}${current}${NC} → ${BOLD}${latest}${NC}"
  echo -e "  Führe ${CYAN}mono update${NC} aus um zu aktualisieren"
  echo ""
}

# ─── Versionen auflisten ──────────────────────────────────────────────────
update::list_versions() {
  local current
  current="$(update::current_version)"

  echo ""
  echo -e "${BOLD}Verfügbare Versionen${NC}"
  echo ""

  local tags
  tags="$(update::fetch_tags)"

  if [[ -z "${tags}" ]]; then
    mono::error "Konnte keine Versionen von GitHub laden"
    return 1
  fi

  while IFS= read -r tag; do
    local version_bare="${tag#v}"
    if [[ "${current}" == "${tag}" || "${current}" == "${version_bare}" ]]; then
      echo -e "  ${GREEN}${tag}${NC} ← aktuell"
    else
      echo -e "  ${CYAN}${tag}${NC}"
    fi
  done <<< "${tags}"

  echo ""
}

# ─── Download und Installation ─────────────────────────────────────────────
update::install() {
  local version="$1"
  local current
  current="$(update::current_version)"

  # Version validieren
  if [[ -z "${version}" ]]; then
    version="$(update::latest_version)"
    if [[ -z "${version}" ]]; then
      mono::error "Konnte neueste Version nicht ermitteln"
      return 1
    fi
  fi

  # Prüfen ob schon auf dem Stand
  local version_bare="${version#v}"
  if [[ "${current}" == "${version}" || "${current}" == "${version_bare}" ]]; then
    mono::log "Bereits auf Version ${BOLD}${version}${NC}"
    return 0
  fi

  mono::log "Update: ${BOLD}${current}${NC} → ${BOLD}${version}${NC}"

  # Temporäres Verzeichnis
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap "rm -rf '${tmp_dir}'" RETURN

  # Tarball herunterladen
  local tarball_url="https://github.com/${MONO_REPO}/archive/refs/tags/${version}.tar.gz"
  mono::log "Lade ${BOLD}${version}${NC} herunter..."

  if ! curl -fsSL "${tarball_url}" -o "${tmp_dir}/mono.tar.gz" 2>/dev/null; then
    mono::error "Download fehlgeschlagen"
    mono::warn "Version ${BOLD}${version}${NC} existiert möglicherweise nicht"
    mono::warn "Verfügbare Versionen: ${CYAN}mono update --list${NC}"
    return 1
  fi

  # Entpacken
  if ! tar -xzf "${tmp_dir}/mono.tar.gz" -C "${tmp_dir}" 2>/dev/null; then
    mono::error "Entpacken fehlgeschlagen"
    return 1
  fi

  # Extrahiertes Verzeichnis finden
  local extracted_dir
  extracted_dir="$(find "${tmp_dir}" -maxdepth 1 -type d -name 'mono-*' | head -1)"

  if [[ -z "${extracted_dir}" || ! -d "${extracted_dir}/.mono" ]]; then
    mono::error "Ungültiges Archiv: .mono Verzeichnis nicht gefunden"
    return 1
  fi

  # ─── Dateien aktualisieren ──────────────────────────────────────────────
  mono::log "Aktualisiere Dateien..."

  # Core-Verzeichnisse ersetzen
  for dir in bin lib commands templates workflows; do
    if [[ -d "${extracted_dir}/.mono/${dir}" ]]; then
      rm -rf "${MONO_DIR}/${dir}"
      cp -R "${extracted_dir}/.mono/${dir}" "${MONO_DIR}/${dir}"
    fi
  done

  # GitHub Workflows: Nur auf Änderungen hinweisen, nicht überschreiben
  update::check_workflow_changes

  # VERSION aktualisieren
  if [[ -f "${extracted_dir}/.mono/VERSION" ]]; then
    cp "${extracted_dir}/.mono/VERSION" "${MONO_VERSION_FILE}"
  else
    echo "${version_bare}" > "${MONO_VERSION_FILE}"
  fi

  # mono Wrapper aktualisieren
  if [[ -f "${extracted_dir}/mono" ]]; then
    cp "${extracted_dir}/mono" "${MONO_ROOT}/mono"
    chmod +x "${MONO_ROOT}/mono"
  fi

  # Berechtigungen setzen
  chmod +x "${MONO_DIR}/bin/mono"

  local new_version
  new_version="$(update::current_version)"
  echo ""
  mono::log "Erfolgreich auf ${BOLD}${new_version}${NC} aktualisiert!"
  echo ""
}

# ─── Workflow-Änderungen prüfen ────────────────────────────────────────────
update::check_workflow_changes() {
  [[ -d "${MONO_DIR}/workflows" ]] || return 0

  local changed=()
  local new_files=()

  for wf in "${MONO_DIR}/workflows/"*.yml; do
    [[ -f "${wf}" ]] || continue
    local name
    name="$(basename "${wf}")"
    local target="${MONO_ROOT}/.github/workflows/${name}"

    if [[ ! -f "${target}" ]]; then
      new_files+=("${name}")
    elif ! diff -q "${wf}" "${target}" &>/dev/null; then
      changed+=("${name}")
    fi
  done

  if [[ ${#changed[@]} -eq 0 && ${#new_files[@]} -eq 0 ]]; then
    mono::log "GitHub Workflows sind aktuell"
    return 0
  fi

  echo ""
  mono::warn "Workflow-Änderungen erkannt:"
  for name in "${changed[@]}"; do
    echo -e "  ${YELLOW}geändert${NC}  ${name}"
  done
  for name in "${new_files[@]}"; do
    echo -e "  ${GREEN}neu${NC}       ${name}"
  done
  echo ""
  echo -e "  Die Workflows in ${BOLD}.github/workflows/${NC} wurden ${BOLD}nicht${NC} überschrieben."
  echo -e "  Verwende ${CYAN}mono update --sync-workflows [prefix]${NC} um die neuen"
  echo -e "  Versionen mit einem Prefix ins Workflow-Verzeichnis zu kopieren."
  echo -e "  Beispiel: ${CYAN}mono update --sync-workflows updated.${NC}"
  echo -e "            → ${BOLD}.github/workflows/updated.deploy.yml${NC}"
  echo ""
}

# ─── Workflows mit Prefix synchronisieren ─────────────────────────────────
update::sync_workflows() {
  local prefix="${1:-}"

  if [[ -z "${prefix}" ]]; then
    mono::error "Prefix fehlt: --sync-workflows <prefix>"
    echo ""
    echo -e "  ${BOLD}Beispiel:${NC} ${CYAN}mono update --sync-workflows updated.${NC}"
    echo -e "  Kopiert neue Workflow-Versionen als ${BOLD}updated.<name>.yml${NC}"
    echo ""
    return 1
  fi

  [[ -d "${MONO_DIR}/workflows" ]] || {
    mono::error "Keine Workflows in .mono/workflows gefunden"
    return 1
  }

  mkdir -p "${MONO_ROOT}/.github/workflows"

  local copied=0
  for wf in "${MONO_DIR}/workflows/"*.yml; do
    [[ -f "${wf}" ]] || continue
    local name
    name="$(basename "${wf}")"
    local target="${MONO_ROOT}/.github/workflows/${name}"
    local prefixed="${MONO_ROOT}/.github/workflows/${prefix}${name}"

    # Nur kopieren wenn es Unterschiede gibt oder die Datei neu ist
    if [[ ! -f "${target}" ]] || ! diff -q "${wf}" "${target}" &>/dev/null; then
      cp "${wf}" "${prefixed}"
      mono::log "Kopiert: ${BOLD}${prefix}${name}${NC}"
      ((copied++))
    fi
  done

  if [[ ${copied} -eq 0 ]]; then
    mono::log "Keine Workflow-Änderungen zum Kopieren"
  else
    echo ""
    mono::log "${BOLD}${copied}${NC} Workflow(s) nach ${BOLD}.github/workflows/${NC} kopiert"
    echo -e "  Vergleiche die ${BOLD}${prefix}*${NC} Dateien mit den bestehenden Workflows"
    echo -e "  und übernimm die Änderungen manuell."
    echo ""
  fi
}

# ─── Command Dispatcher ───────────────────────────────────────────────────
update::run() {
  local target_version=""
  local mode="update"
  local sync_prefix=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        target_version="${2:-}"
        if [[ -z "${target_version}" ]]; then
          mono::error "Version fehlt: --version <tag>"
          return 1
        fi
        shift 2
        ;;
      --check)
        mode="check"
        shift
        ;;
      --list)
        mode="list"
        shift
        ;;
      --sync-workflows)
        mode="sync-workflows"
        sync_prefix="${2:-}"
        [[ -n "${sync_prefix}" ]] && shift
        shift
        ;;
      --help|-h)
        update::help
        return 0
        ;;
      *)
        mono::error "Unbekannte Option: $1"
        update::help
        return 1
        ;;
    esac
  done

  case "${mode}" in
    check)
      update::check
      ;;
    list)
      update::list_versions
      ;;
    sync-workflows)
      update::sync_workflows "${sync_prefix}"
      ;;
    update)
      update::install "${target_version}"
      ;;
  esac
}

# ─── Start ──────────────────────────────────────────────────────────────────
update::run "$@"
