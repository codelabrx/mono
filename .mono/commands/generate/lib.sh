#!/usr/bin/env bash
# description: Erstellt eine neue Library im libs/ Verzeichnis

TEMPLATES_DIR="${MONO_DIR}/templates/lib"

# ─── Verfügbare Templates auflisten ─────────────────────────────────────────
lib::list_templates() {
  local templates=()
  if [[ -d "${TEMPLATES_DIR}" ]]; then
    for d in "${TEMPLATES_DIR}"/*/; do
      [[ -d "$d" ]] || continue
      templates+=("$(basename "$d")")
    done
  fi
  echo "${templates[@]}"
}

lib::help() {
  echo ""
  echo -e "${BOLD}mono generate lib${NC} – Neue Library erstellen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono generate lib <name> [--template <template>]"
  echo ""
  echo -e "${BOLD}Name-Format:${NC}"
  echo "  lib-name              → libs/lib-name/"
  echo "  subfolder/lib-name    → libs/subfolder/lib-name/"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --template, -t <name>   Template auswählen (Standard: interaktive Auswahl)"
  echo ""
  echo -e "${BOLD}Verfügbare Templates:${NC}"

  for t in $(lib::list_templates); do
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
lib::select_template() {
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
    i=$((i + 1))
  done

  echo ""
  read -rp "Template wählen [1-${#templates[@]}]: " choice

  if [[ -z "${choice}" || "${choice}" -lt 1 || "${choice}" -gt ${#templates[@]} ]] 2>/dev/null; then
    mono::error "Ungültige Auswahl"
    return 1
  fi

  echo "${templates[$((choice - 1))]}"
}

# ─── Lib generieren ───────────────────────────────────────────────────────
lib::generate() {
  local name=""
  local template=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template|-t)
        template="${2:-}"
        shift 2
        ;;
      --help|-h)
        lib::help
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

  if [[ -z "${name}" ]]; then
    mono::error "Kein Lib-Name angegeben"
    lib::help
    return 1
  fi

  local target_dir="${MONO_ROOT}/libs/${name}"

  if [[ -d "${target_dir}" ]]; then
    mono::error "Library existiert bereits: ${BOLD}libs/${name}${NC}"
    return 1
  fi

  if [[ -z "${template}" ]]; then
    template="$(lib::select_template)" || return 1
  fi

  local template_dir="${TEMPLATES_DIR}/${template}"

  if [[ ! -d "${template_dir}" ]]; then
    mono::error "Template nicht gefunden: ${BOLD}${template}${NC}"
    echo ""
    echo "Verfügbare Templates: $(lib::list_templates)"
    return 1
  fi

  local lib_name
  lib_name="$(basename "${name}")"

  mkdir -p "${target_dir}"

  local file_count=0
  while IFS= read -r -d '' file; do
    local rel_path="${file#"${template_dir}/"}"
    [[ "${rel_path}" == ".template" ]] && continue

    local dest="${target_dir}/${rel_path}"
    mkdir -p "$(dirname "${dest}")"

    sed \
      -e "s|{{LIB_NAME}}|${lib_name}|g" \
      -e "s|{{LIB_PATH}}|${name}|g" \
      "${file}" > "${dest}"

    file_count=$((file_count + 1))
  done < <(find "${template_dir}" -type f -print0)

  echo ""
  mono::log "Library erstellt: ${BOLD}libs/${name}${NC} (Template: ${template})"
  mono::log "${file_count} Datei(en) generiert"

  local template_meta="${template_dir}/.template"
  local init_cmd=""
  if [[ -f "${template_meta}" ]]; then
    init_cmd="$(grep '^init:' "${template_meta}" | sed 's/^init:[[:space:]]*//' | head -1 || true)"
  fi

  if [[ -n "${init_cmd}" ]]; then
    echo ""
    mono::log "Post-Init: ${BOLD}${init_cmd}${NC}"
    echo ""
    (cd "${target_dir}" && eval "${init_cmd}")
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
      mono::warn "Post-Init Command beendet mit Exit-Code ${exit_code}"
    fi
  fi

  echo ""
  echo -e "${BOLD}Erstellt:${NC}"
  (cd "${MONO_ROOT}" && find "libs/${name}" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' | sort | sed 's/^/  /')
  echo ""

  # Workspace-Links aktualisieren (Libs sind Root-Workspace-Members)
  if [[ -f "${MONO_ROOT}/package.json" ]]; then
    echo ""
    mono::log "Workspace-Links aktualisieren..."
    (cd "${MONO_ROOT}" && bun install)
  fi
}

lib::generate "$@"
