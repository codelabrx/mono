#!/usr/bin/env bash
# description: Zeigt geänderte Apps/Libs seit dem letzten Deploy

DEPLOY_REF="${MONO_DEPLOY_REF:-refs/deploy/latest}"

changed::normalize_ref() {
  local ref="$1"

  if [[ "${ref}" == refs/* ]]; then
    echo "${ref}"
  else
    echo "refs/${ref}"
  fi
}

changed::ref_for_env() {
  local env_name="$1"
  echo "refs/deploy/${env_name}-latest"
}

# ─── Help ───────────────────────────────────────────────────────────────────
changed::help() {
  echo ""
  echo -e "${BOLD}mono changed${NC} – Änderungserkennung"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono changed [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --env <name>        Environment nutzen (setzt refs/deploy/<name>-latest)"
  echo "  --ref <ref>         Git-Ref als Vergleichsbasis (Standard: ${DEPLOY_REF})"
  echo "  --apps              Nur geänderte Apps anzeigen"
  echo "  --libs              Nur geänderte Libs anzeigen"
  echo "  --json              Ausgabe als JSON"
  echo "  --quiet, -q         Nur Pfade ausgeben (eine pro Zeile)"
  echo "  --help, -h          Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono changed                        # Alle Änderungen seit refs/deploy/latest"
  echo "  mono changed --env dev              # Alle Änderungen seit refs/deploy/dev-latest"
  echo "  mono changed --apps                 # Nur geänderte Apps"
  echo "  mono changed --ref main~5           # Vergleich mit 5 Commits zurück"
  echo "  mono changed --json                 # JSON-Ausgabe für CI/CD"
  echo "  mono changed --quiet | xargs -I{} echo 'deploy {}'"
  echo ""
  echo -e "${BOLD}Deploy-Ref setzen:${NC}"
  echo "  mono deploy-mark                    # Setzt ${DEPLOY_REF} auf HEAD"
  echo ""
  echo -e "${BOLD}Projekterkennung:${NC}"
  echo "  Projekte werden anhand einer ${BOLD}project.json${NC} im Verzeichnis erkannt."
  echo ""
}

# ─── Geänderte Dateien ermitteln ────────────────────────────────────────────
changed::get_changed_files() {
  local base_ref="$1"

  if ! git rev-parse --verify "${base_ref}" &>/dev/null; then
    return 1
  fi

  git -C "${MONO_ROOT}" diff --name-only "${base_ref}"..HEAD 2>/dev/null
}

# ─── Projekt-Root anhand project.json finden ────────────────────────────────
# Geht vom geänderten File aufwärts und sucht das nächste project.json
changed::find_project_root() {
  local base="$1"    # "apps" oder "libs"
  local rel="$2"     # relativer Pfad ohne apps/ bzw. libs/

  local parts
  IFS='/' read -ra parts <<< "${rel}"

  # Von der Datei aufwärts nach project.json suchen
  local accumulated="${base}"
  local best_match=""

  for ((i = 0; i < ${#parts[@]} - 1; i++)); do
    accumulated="${accumulated}/${parts[$i]}"
    local full_path="${MONO_ROOT}/${accumulated}"

    if [[ -f "${full_path}/project.json" ]]; then
      best_match="${accumulated}"
      break  # Erstes (nächstes zur Wurzel) project.json gewinnt
    fi
  done

  # Fallback: erste Ebene unter apps/libs
  if [[ -z "${best_match}" ]]; then
    best_match="${base}/${parts[0]}"
  fi

  echo "${best_match}"
}

# ─── project.json lesen ────────────────────────────────────────────────────
# Liest ein Feld aus der project.json (ohne jq-Abhängigkeit)
changed::read_project_field() {
  local project_path="$1"
  local field="$2"
  local project_file="${MONO_ROOT}/${project_path}/project.json"

  if [[ ! -f "${project_file}" ]]; then
    echo ""
    return
  fi

  grep -m1 "\"${field}\"" "${project_file}" 2>/dev/null \
    | sed 's/.*: *"\{0,1\}//; s/"\{0,1\} *,\{0,1\} *$//' \
    || echo ""
}

# ─── Deploy-Strategie lesen ───────────────────────────────────────────────
changed::read_project_deploy() {
  local project_path="$1"
  local project_file="${MONO_ROOT}/${project_path}/project.json"

  if [[ ! -f "${project_file}" ]]; then
    echo "none"
    return
  fi

  grep -m1 '"strategy"' "${project_file}" 2>/dev/null \
    | sed 's/.*: *"//; s/" *,\{0,1\} *$//' \
    || echo "none"
}

# ─── Geänderte Projekte extrahieren ─────────────────────────────────────────
changed::extract_projects() {
  local filter="$1"  # "all", "apps", "libs"
  local -a files=()

  while IFS= read -r file; do
    files+=("${file}")
  done

  local projects=""

  for file in "${files[@]}"; do
    local project_path=""

    case "${file}" in
      apps/*)
        [[ "${filter}" == "libs" ]] && continue
        local rel="${file#apps/}"
        [[ "${rel}" != */* ]] && continue
        project_path="$(changed::find_project_root "apps" "${rel}")"
        ;;
      libs/*)
        [[ "${filter}" == "apps" ]] && continue
        local rel="${file#libs/}"
        [[ "${rel}" != */* ]] && continue
        project_path="$(changed::find_project_root "libs" "${rel}")"
        ;;
      *)
        [[ "${filter}" != "all" ]] && continue
        project_path="."
        ;;
    esac

    if [[ -n "${project_path}" ]]; then
      projects="${projects}${project_path}"$'\n'
    fi
  done

  # Deduplizieren und sortieren
  echo "${projects}" | grep -v '^$' | sort -u
}

# ─── Hauptfunktion ─────────────────────────────────────────────────────────
changed::run() {
  local base_ref=""
  local env_name=""
  local filter="all"
  local output="pretty"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        env_name="${2:-}"
        if [[ -z "${env_name}" ]]; then
          mono::error "Option --env benötigt einen Wert"
          return 1
        fi
        base_ref="$(changed::ref_for_env "${env_name}")"
        shift 2
        ;;
      --env=*)
        env_name="${1#--env=}"
        if [[ -z "${env_name}" ]]; then
          mono::error "Option --env benötigt einen Wert"
          return 1
        fi
        base_ref="$(changed::ref_for_env "${env_name}")"
        shift
        ;;
      --tag|--ref) base_ref="${2:-}"; shift 2 ;;
      --apps)    filter="apps"; shift ;;
      --libs)    filter="libs"; shift ;;
      --json)    output="json"; shift ;;
      --quiet|-q) output="quiet"; shift ;;
      --help|-h) changed::help; return 0 ;;
      *)
        mono::error "Unbekannte Option: $1"
        changed::help
        return 1
        ;;
    esac
  done

  if [[ -z "${base_ref}" ]]; then
    base_ref="${DEPLOY_REF}"
  fi

  base_ref="$(changed::normalize_ref "${base_ref}")"

  if ! git -C "${MONO_ROOT}" rev-parse --verify "${base_ref}" &>/dev/null; then
    if [[ "${base_ref}" == "${DEPLOY_REF}" ]]; then
      mono::warn "Deploy-Ref ${BOLD}${base_ref}${NC} existiert noch nicht."
      mono::warn "Verwende den initialen Commit als Basis."
      base_ref="$(git -C "${MONO_ROOT}" rev-list --max-parents=0 HEAD | head -1)"
    else
      mono::error "Git-Ref nicht gefunden: ${BOLD}${base_ref}${NC}"
      return 1
    fi
  fi

  local base_sha head_sha
  base_sha="$(git -C "${MONO_ROOT}" rev-parse --short "${base_ref}")"
  head_sha="$(git -C "${MONO_ROOT}" rev-parse --short HEAD)"

  local changed_files
  changed_files="$(changed::get_changed_files "${base_ref}")"

  if [[ -z "${changed_files}" ]]; then
    changed::output_empty "${output}" "${base_sha}" "${head_sha}" "${base_ref}"
    return 0
  fi

  local projects
  projects="$(echo "${changed_files}" | changed::extract_projects "${filter}")"

  if [[ -z "${projects}" ]]; then
    changed::output_empty "${output}" "${base_sha}" "${head_sha}" "${base_ref}"
    return 0
  fi

  case "${output}" in
    json)   changed::output_json "${projects}" "${base_sha}" "${head_sha}" ;;
    quiet)  echo "${projects}" ;;
    pretty) changed::output_pretty "${projects}" "${base_sha}" "${head_sha}" "${base_ref}" ;;
  esac
}

# ─── Ausgabe: leer ──────────────────────────────────────────────────────────
changed::output_empty() {
  local output="$1" base_sha="$2" head_sha="$3" base_ref="$4"
  case "${output}" in
    json)  echo "{\"base\":\"${base_sha}\",\"head\":\"${head_sha}\",\"changed\":[]}" ;;
    quiet) : ;;
    *)     mono::log "Keine Änderungen seit ${BOLD}${base_ref}${NC} (${base_sha})" ;;
  esac
}

# ─── Ausgabe: JSON (mit project.json-Daten) ─────────────────────────────────
changed::output_json() {
  local projects="$1" base_sha="$2" head_sha="$3"
  local items=""

  while IFS= read -r project; do
    [[ -z "${project}" ]] && continue

    local type="other"
    [[ "${project}" == apps/* ]] && type="app"
    [[ "${project}" == libs/* ]] && type="lib"

    local name strategy
    name="$(changed::read_project_field "${project}" "name")"
    strategy="$(changed::read_project_deploy "${project}")"

    [[ -z "${name}" ]] && name="$(basename "${project}")"
    [[ -z "${strategy}" ]] && strategy="none"

    [[ -n "${items}" ]] && items="${items},"
    items="${items}{\"path\":\"${project}\",\"name\":\"${name}\",\"type\":\"${type}\",\"deploy\":{\"strategy\":\"${strategy}\"}}"
  done <<< "${projects}"

  echo "{\"base\":\"${base_sha}\",\"head\":\"${head_sha}\",\"changed\":[${items}]}"
}

# ─── Ausgabe: Pretty (mit Deploy-Infos) ────────────────────────────────────
changed::output_pretty() {
  local projects="$1" base_sha="$2" head_sha="$3" base_ref="$4"

  echo ""
  mono::log "Änderungen: ${BOLD}${base_ref}${NC} (${base_sha}) → HEAD (${head_sha})"
  echo ""

  local app_count=0 lib_count=0 other_count=0

  while IFS= read -r project; do
    [[ -z "${project}" ]] && continue

    local icon=""
    if [[ "${project}" == apps/* ]]; then
      icon="📦"; app_count=$((app_count + 1))
    elif [[ "${project}" == libs/* ]]; then
      icon="📚"; lib_count=$((lib_count + 1))
    else
      icon="📄"; other_count=$((other_count + 1))
    fi

    local name strategy has_project_json
    local project_file="${MONO_ROOT}/${project}/project.json"

    if [[ -f "${project_file}" ]]; then
      has_project_json=true
      name="$(changed::read_project_field "${project}" "name")"
      strategy="$(changed::read_project_deploy "${project}")"
    else
      has_project_json=false
      name="$(basename "${project}")"
      strategy="none"
    fi

    [[ -z "${name}" ]] && name="$(basename "${project}")"
    [[ -z "${strategy}" ]] && strategy="none"

    local deploy_info=""
    if [[ "${strategy}" != "none" ]]; then
      deploy_info=" ${YELLOW}→ deploy: ${strategy}${NC}"
    fi

    local warning=""
    if [[ "${has_project_json}" == false && "${project}" != "." ]]; then
      warning=" ${RED}(project.json fehlt!)${NC}"
    fi

    echo -e "  ${icon} ${CYAN}${project}${NC}${deploy_info}${warning}"
  done <<< "${projects}"

  echo ""
  local summary=""
  [[ ${app_count} -gt 0 ]] && summary="${app_count} App(s)"
  [[ ${lib_count} -gt 0 ]] && summary="${summary:+${summary}, }${lib_count} Lib(s)"
  [[ ${other_count} -gt 0 ]] && summary="${summary:+${summary}, }${other_count} Root"
  mono::log "Gesamt: ${summary}"
  echo ""
}

# ─── Start ──────────────────────────────────────────────────────────────────
changed::run "$@"
