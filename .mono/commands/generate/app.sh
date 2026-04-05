#!/usr/bin/env bash
# description: Erstellt eine neue App im apps/ Verzeichnis

TEMPLATES_DIR="${MONO_DIR}/templates/app"

# ─── Verfügbare Templates auflisten ─────────────────────────────────────────
app::list_templates() {
  local templates=()
  if [[ -d "${TEMPLATES_DIR}" ]]; then
    for d in "${TEMPLATES_DIR}"/*/; do
      [[ -d "$d" ]] || continue
      templates+=("$(basename "$d")")
    done
  fi
  echo "${templates[@]}"
}

app::help() {
  echo ""
  echo -e "${BOLD}mono generate app${NC} – Neue App erstellen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono generate app <name> [--template <template>]"
  echo ""
  echo -e "${BOLD}Name-Format:${NC}"
  echo "  app-name              → apps/app-name/"
  echo "  subfolder/app-name    → apps/subfolder/app-name/"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --template, -t <name>   Template auswählen (Standard: interaktive Auswahl)"
  echo ""
  echo -e "${BOLD}Verfügbare Templates:${NC}"

  for t in $(app::list_templates); do
    local desc_file="${TEMPLATES_DIR}/${t}/.template"
    local desc=""
    if [[ -f "${desc_file}" ]]; then
      desc="$(head -1 "${desc_file}")"
    fi
    printf "  ${CYAN}%-16s${NC} %s\n" "${t}" "${desc}"
  done

  echo ""
}

# ─── Interaktive Template-Auswahl ──────────────────────────────────────────
app::select_template() {
  local templates=()
  for d in "${TEMPLATES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    templates+=("$(basename "$d")")
  done

  if [[ ${#templates[@]} -eq 0 ]]; then
    mono::error "Keine Templates gefunden in ${TEMPLATES_DIR}"
    return 1
  fi

  echo ""
  echo -e "${BOLD}Verfügbare Templates:${NC}"
  local i=1
  for t in "${templates[@]}"; do
    local desc_file="${TEMPLATES_DIR}/${t}/.template"
    local desc=""
    if [[ -f "${desc_file}" ]]; then
      desc=" – $(head -1 "${desc_file}")"
    fi
    echo -e "  ${CYAN}${i})${NC} ${t}${desc}"
    ((i++))
  done

  echo ""
  read -rp "Template wählen [1-${#templates[@]}]: " choice

  if [[ -z "${choice}" || "${choice}" -lt 1 || "${choice}" -gt ${#templates[@]} ]] 2>/dev/null; then
    mono::error "Ungültige Auswahl"
    return 1
  fi

  echo "${templates[$((choice - 1))]}"
}

# ─── App generieren ────────────────────────────────────────────────────────
app::generate() {
  local name=""
  local template=""

  # Argumente parsen
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template|-t)
        template="${2:-}"
        shift 2
        ;;
      --help|-h)
        app::help
        return 0
        ;;
      *)
        if [[ -z "${name}" ]]; then
          name="$1"
        else
          mono::error "Unerwartetes Argument: $1"
          return 1
        fi
        shift
        ;;
    esac
  done

  # Name prüfen
  if [[ -z "${name}" ]]; then
    mono::error "Kein App-Name angegeben"
    app::help
    return 1
  fi

  # Zielverzeichnis bestimmen
  local target_dir="${MONO_ROOT}/apps/${name}"

  # Prüfen ob bereits existiert
  if [[ -d "${target_dir}" ]]; then
    mono::error "App existiert bereits: ${BOLD}apps/${name}${NC}"
    return 1
  fi

  # Template auswählen (interaktiv falls nicht angegeben)
  if [[ -z "${template}" ]]; then
    template="$(app::select_template)" || return 1
  fi

  local template_dir="${TEMPLATES_DIR}/${template}"

  if [[ ! -d "${template_dir}" ]]; then
    mono::error "Template nicht gefunden: ${BOLD}${template}${NC}"
    echo ""
    echo "Verfügbare Templates: $(app::list_templates)"
    return 1
  fi

  # App-Name (letzter Teil des Pfades) für Platzhalter
  local app_name
  app_name="$(basename "${name}")"

  # Verzeichnis erstellen
  mkdir -p "${target_dir}"

  # Template-Dateien kopieren (ohne .template Metadatei)
  local file_count=0
  while IFS= read -r -d '' file; do
    local rel_path="${file#"${template_dir}/"}"

    # .template Metadatei überspringen
    [[ "${rel_path}" == ".template" ]] && continue

    local dest="${target_dir}/${rel_path}"
    mkdir -p "$(dirname "${dest}")"

    # Platzhalter ersetzen
    sed \
      -e "s|{{APP_NAME}}|${app_name}|g" \
      -e "s|{{APP_PATH}}|${name}|g" \
      "${file}" > "${dest}"

    ((file_count++))
  done < <(find "${template_dir}" -type f -print0)

  echo ""
  mono::log "App erstellt: ${BOLD}apps/${name}${NC} (Template: ${template})"
  mono::log "${file_count} Datei(en) generiert"
  echo ""

  # Verzeichnisinhalt anzeigen
  echo -e "${BOLD}Erstellt:${NC}"
  (cd "${MONO_ROOT}" && find "apps/${name}" -type f | sort | sed 's/^/  /')
  echo ""
}

# ─── Start ──────────────────────────────────────────────────────────────────
app::generate "$@"
