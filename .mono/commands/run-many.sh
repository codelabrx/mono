#!/usr/bin/env bash
# description: Führt ein Target über mehrere Projekte aus

# Graph-Library laden
source "${MONO_DIR}/lib/graph.sh"

# ─── Help ───────────────────────────────────────────────────────────────────
run_many::help() {
  echo ""
  echo -e "${BOLD}mono run-many${NC} – Target über mehrere Projekte ausführen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono run-many --target <target> [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --target, -t <name>   Target das ausgeführt werden soll (pflicht)"
  echo "  --projects <list>     Komma-separierte Liste von Projektnamen"
  echo "  --apps                Nur Apps"
  echo "  --libs                Nur Libs"
  echo "  --skip-deps           dependsOn-Kette überspringen"
  echo "  --dry-run             Zeigt was ausgeführt würde"
  echo "  --continue-on-error   Bei Fehler weitermachen"
  echo "  --help, -h            Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Hinweis:${NC}"
  echo "  Projekte werden in topologischer Reihenfolge ausgeführt"
  echo "  (Dependencies zuerst, basierend auf project.json dependencies)."
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono run-many --target build            # build in allen Projekten"
  echo "  mono run-many --target test --apps      # test nur in Apps"
  echo "  mono run-many --target lint --libs      # lint nur in Libs"
  echo "  mono run-many --target build --projects my-app,my-lib"
  echo "  mono run-many --target build --dry-run  # Zeigt Ausführungsplan"
  echo ""
}

# ─── Prüfen ob ein Target in einem Projekt existiert ───────────────────────
run_many::has_target() {
  local project_dir="$1"
  local target="$2"
  local project_file="${MONO_ROOT}/${project_dir}/project.json"

  [[ -f "${project_file}" ]] || return 1

  local block
  block="$(sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${project_file}")"
  [[ -n "${block}" ]]
}

# ─── Target mit dependsOn ausführen ────────────────────────────────────────
run_many::execute_with_deps() {
  local project_dir="$1"
  local target="$2"
  local skip_deps="$3"
  local _executed="$4"

  local project_file="${MONO_ROOT}/${project_dir}/project.json"
  local full_dir="${MONO_ROOT}/${project_dir}"

  # Prüfen ob Target bereits ausgeführt
  if [[ ",${_executed}," == *",${target},"* ]]; then
    return 0
  fi

  # Command lesen
  local command
  command="$(sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${project_file}" \
    | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

  if [[ -z "${command}" ]]; then
    mono::error "Target ${BOLD}${target}${NC} nicht gefunden in ${project_dir}/project.json"
    return 1
  fi

  # DependsOn auflösen
  if [[ "${skip_deps}" != "true" ]]; then
    local deps_block
    deps_block="$(sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${project_file}")"
    local deps_line
    deps_line="$(echo "${deps_block}" | grep '"dependsOn"' | head -1)"

    if [[ -n "${deps_line}" ]]; then
      local deps
      deps="$(echo "${deps_line}" | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | sed 's/[[:space:]]*"//g; /^$/d')"

      while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        run_many::execute_with_deps "${project_dir}" "${dep}" "${skip_deps}" "${_executed}" || return 1
        _executed="${_executed:+${_executed},}${dep}"
      done <<< "${deps}"
    fi
  fi

  # Ausführen
  local proj_name
  proj_name="$(graph::json_field "${project_file}" "name")"
  [[ -z "${proj_name}" ]] && proj_name="$(basename "${project_dir}")"

  mono::log "${BOLD}${proj_name}:${target}${NC} → ${command}"

  (cd "${full_dir}" && eval "${command}")
  local exit_code=$?

  if [[ ${exit_code} -ne 0 ]]; then
    mono::error "Target ${BOLD}${target}${NC} fehlgeschlagen (Exit: ${exit_code})"
    return ${exit_code}
  fi

  mono::log "Target ${BOLD}${target}${NC} abgeschlossen ✓"
  return 0
}

# ─── Hauptfunktion ─────────────────────────────────────────────────────────
run_many::run() {
  local target=""
  local filter="all"
  local skip_deps=false
  local dry_run=false
  local continue_on_error=false
  local projects_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target|-t)  target="${2:-}"; shift 2 ;;
      --projects)   projects_filter="${2:-}"; shift 2 ;;
      --apps)       filter="apps"; shift ;;
      --libs)       filter="libs"; shift ;;
      --skip-deps)  skip_deps=true; shift ;;
      --dry-run)    dry_run=true; shift ;;
      --continue-on-error) continue_on_error=true; shift ;;
      --help|-h)    run_many::help; return 0 ;;
      *)
        mono::error "Unbekannte Option: $1"
        run_many::help
        return 1
        ;;
    esac
  done

  if [[ -z "${target}" ]]; then
    mono::error "Kein Target angegeben. Verwende --target <name>"
    run_many::help
    return 1
  fi

  # ─── Graph aufbauen ─────────────────────────────────────────────────────
  graph::build

  # ─── Projekte ermitteln ─────────────────────────────────────────────────
  local -a projects=()

  if [[ -n "${projects_filter}" ]]; then
    IFS=',' read -ra proj_names <<< "${projects_filter}"
    for name in "${proj_names[@]}"; do
      name="$(echo "${name}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      local proj_dir
      proj_dir="$(graph::resolve_project "${name}")" || {
        mono::error "Projekt nicht gefunden: ${BOLD}${name}${NC}"
        return 1
      }
      projects+=("${proj_dir}")
    done
  else
    while IFS= read -r proj; do
      [[ -n "${proj}" ]] && projects+=("${proj}")
    done < <(graph::find_all_projects)

    # Filter anwenden
    if [[ "${filter}" != "all" ]]; then
      local -a filtered=()
      for proj in "${projects[@]}"; do
        case "${filter}" in
          apps) [[ "${proj}" == apps/* ]] && filtered+=("${proj}") ;;
          libs) [[ "${proj}" == libs/* ]] && filtered+=("${proj}") ;;
        esac
      done
      projects=("${filtered[@]}")
    fi
  fi

  if [[ ${#projects[@]} -eq 0 ]]; then
    mono::warn "Keine Projekte gefunden"
    return 0
  fi

  # ─── Projekte filtern: nur die mit dem gewünschten Target ──────────────
  local -a matching_projects=()
  local -a skipped_projects=()

  for proj in "${projects[@]}"; do
    if run_many::has_target "${proj}" "${target}"; then
      matching_projects+=("${proj}")
    else
      skipped_projects+=("${proj}")
    fi
  done

  if [[ ${#matching_projects[@]} -eq 0 ]]; then
    mono::warn "Kein Projekt hat das Target ${BOLD}${target}${NC}"
    return 0
  fi

  # ─── Topologische Sortierung ───────────────────────────────────────────
  local matching_list=""
  for proj in "${matching_projects[@]}"; do
    matching_list="${matching_list}${proj}"$'\n'
  done

  local sorted_projects
  sorted_projects="$(graph::topo_sort "${matching_list}")" || return 1

  # Sortierte Liste in Array konvertieren
  local -a ordered_projects=()
  while IFS= read -r proj; do
    [[ -n "${proj}" ]] && ordered_projects+=("${proj}")
  done <<< "${sorted_projects}"

  # ─── Ausgabe ──────────────────────────────────────────────────────────
  echo ""
  mono::log "Target ${BOLD}${target}${NC} in ${#ordered_projects[@]} Projekt(en) (topologisch sortiert)"

  if [[ ${#skipped_projects[@]} -gt 0 ]]; then
    mono::warn "${#skipped_projects[@]} Projekt(e) übersprungen (Target nicht vorhanden)"
  fi

  if [[ "${dry_run}" == true ]]; then
    echo ""
    echo -e "${BOLD}Ausführungsplan (Reihenfolge):${NC}"
    local i=1
    for proj in "${ordered_projects[@]}"; do
      local name
      name="$(graph::name_of "${proj}")"
      [[ -z "${name}" ]] && name="$(basename "${proj}")"

      local deps
      deps="$(graph::deps_of "${proj}")"
      local dep_str=""
      if [[ -n "${deps}" ]]; then
        local dep_names=""
        while IFS= read -r d; do
          [[ -z "${d}" ]] && continue
          local dn
          dn="$(graph::name_of "${d}")"
          dep_names="${dep_names:+${dep_names}, }${dn}"
        done <<< "${deps}"
        dep_str=" ${YELLOW}← ${dep_names}${NC}"
      fi

      echo -e "  ${BOLD}${i}.${NC} ${CYAN}${name}${NC}:${target}  (${proj})${dep_str}"
      ((i++))
    done
    echo ""
    return 0
  fi

  # ─── Ausführung ──────────────────────────────────────────────────────
  local total=${#ordered_projects[@]}
  local current=0
  local failed=0
  local -a failed_projects=()

  for proj in "${ordered_projects[@]}"; do
    ((current++))

    local name
    name="$(graph::name_of "${proj}")"
    [[ -z "${name}" ]] && name="$(basename "${proj}")"

    echo ""
    echo -e "${BOLD}━━━ [${current}/${total}] ${CYAN}${name}${NC}${BOLD}:${target} ━━━${NC}"

    run_many::execute_with_deps "${proj}" "${target}" "${skip_deps}" "" || {
      local exit_code=$?
      ((failed++))
      failed_projects+=("${name}")

      if [[ "${continue_on_error}" != true ]]; then
        echo ""
        mono::error "Abbruch nach Fehler in ${BOLD}${name}:${target}${NC}"
        mono::error "${failed} von ${current} Projekt(en) fehlgeschlagen"
        return ${exit_code}
      fi

      mono::warn "Fehler in ${BOLD}${name}:${target}${NC} – fahre fort"
    }
  done

  # ─── Zusammenfassung ────────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [[ ${failed} -eq 0 ]]; then
    mono::log "Alle ${total} Projekt(e) erfolgreich ✓"
  else
    mono::error "${failed} von ${total} Projekt(en) fehlgeschlagen:"
    for fp in "${failed_projects[@]}"; do
      echo -e "  ${RED}✗${NC} ${fp}"
    done
  fi

  echo ""
  [[ ${failed} -eq 0 ]]
}

# ─── Start ──────────────────────────────────────────────────────────────────
run_many::run "$@"
