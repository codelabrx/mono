#!/usr/bin/env bash
# description: Führt ein Target nur in geänderten Projekten aus

# Graph-Library laden
source "${MONO_DIR}/lib/graph.sh"

DEPLOY_TAG="${MONO_DEPLOY_TAG:-deploy/latest}"

# ─── Help ───────────────────────────────────────────────────────────────────
affected::help() {
  echo ""
  echo -e "${BOLD}mono affected${NC} – Target in geänderten Projekten ausführen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono affected --target <target> [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --target, -t <name>   Target das ausgeführt werden soll (pflicht)"
  echo "  --tag <tag>           Deploy-Tag als Vergleichsbasis (Standard: ${DEPLOY_TAG})"
  echo "  --ref <ref>           Beliebige Git-Ref als Vergleichsbasis"
  echo "  --apps                Nur geänderte Apps"
  echo "  --libs                Nur geänderte Libs"
  echo "  --skip-deps           dependsOn-Kette überspringen"
  echo "  --dry-run             Zeigt was ausgeführt würde"
  echo "  --continue-on-error   Bei Fehler weitermachen"
  echo "  --help, -h            Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Transitive Abhängigkeiten:${NC}"
  echo "  Wenn sich eine Lib ändert, werden alle Projekte die"
  echo "  (direkt oder transitiv) davon abhängen als betroffen erkannt."
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono affected --target test              # test in geänderten Projekten"
  echo "  mono affected --target build --apps      # build nur in geänderten Apps"
  echo "  mono affected --target lint --ref main~3 # lint seit 3 Commits"
  echo "  mono affected --target build --dry-run   # Zeigt Plan"
  echo ""
  echo -e "${BOLD}Kombination mit CI/CD:${NC}"
  echo "  mono affected --target test --continue-on-error"
  echo "  mono affected --target build && mono deploy-mark --push"
  echo ""
}

# ─── Geänderte Dateien ermitteln ────────────────────────────────────────────
affected::get_changed_files() {
  local base_ref="$1"

  if ! git -C "${MONO_ROOT}" rev-parse --verify "${base_ref}" &>/dev/null; then
    return 1
  fi

  git -C "${MONO_ROOT}" diff --name-only "${base_ref}"..HEAD 2>/dev/null
}

# ─── Projekt-Root finden ───────────────────────────────────────────────────
affected::find_project_root() {
  local base="$1"
  local rel="$2"

  local parts
  IFS='/' read -ra parts <<< "${rel}"

  local accumulated="${base}"

  for ((i = 0; i < ${#parts[@]} - 1; i++)); do
    accumulated="${accumulated}/${parts[$i]}"
    local full_path="${MONO_ROOT}/${accumulated}"

    if [[ -f "${full_path}/project.json" ]]; then
      echo "${accumulated}"
      return 0
    fi
  done

  # Fallback: erste Ebene
  if [[ ${#parts[@]} -ge 1 ]]; then
    local fallback="${base}/${parts[0]}"
    if [[ -f "${MONO_ROOT}/${fallback}/project.json" ]]; then
      echo "${fallback}"
      return 0
    fi
  fi

  return 1
}

# ─── Direkt geänderte Projekte extrahieren ──────────────────────────────────
affected::get_directly_changed() {
  local filter="$1"
  local -a files=()

  while IFS= read -r file; do
    [[ -n "${file}" ]] && files+=("${file}")
  done

  local projects=""

  for file in "${files[@]}"; do
    case "${file}" in
      apps/*)
        [[ "${filter}" == "libs" ]] && continue
        local rel="${file#apps/}"
        [[ "${rel}" != */* ]] && continue
        local proj
        proj="$(affected::find_project_root "apps" "${rel}")" || continue
        projects="${projects}${proj}"$'\n'
        ;;
      libs/*)
        [[ "${filter}" == "apps" ]] && continue
        local rel="${file#libs/}"
        [[ "${rel}" != */* ]] && continue
        local proj
        proj="$(affected::find_project_root "libs" "${rel}")" || continue
        projects="${projects}${proj}"$'\n'
        ;;
    esac
  done

  echo "${projects}" | grep -v '^$' | sort -u
}

# ─── Prüfen ob Target existiert ───────────────────────────────────────────
affected::has_target() {
  local project_dir="$1"
  local target="$2"
  local project_file="${MONO_ROOT}/${project_dir}/project.json"

  [[ -f "${project_file}" ]] || return 1

  local block
  block="$(sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${project_file}")"
  [[ -n "${block}" ]]
}

# ─── Target mit dependsOn ausführen ────────────────────────────────────────
affected::execute_with_deps() {
  local project_dir="$1"
  local target="$2"
  local skip_deps="$3"
  local _executed="$4"

  local project_file="${MONO_ROOT}/${project_dir}/project.json"
  local full_dir="${MONO_ROOT}/${project_dir}"

  if [[ ",${_executed}," == *",${target},"* ]]; then
    return 0
  fi

  local command
  command="$(sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${project_file}" \
    | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

  if [[ -z "${command}" ]]; then
    mono::error "Target ${BOLD}${target}${NC} nicht gefunden in ${project_dir}/project.json"
    return 1
  fi

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
        affected::execute_with_deps "${project_dir}" "${dep}" "${skip_deps}" "${_executed}" || return 1
        _executed="${_executed:+${_executed},}${dep}"
      done <<< "${deps}"
    fi
  fi

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
affected::run() {
  local target=""
  local base_ref=""
  local filter="all"
  local skip_deps=false
  local dry_run=false
  local continue_on_error=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target|-t)  target="${2:-}"; shift 2 ;;
      --tag)        base_ref="${2:-}"; shift 2 ;;
      --ref)        base_ref="${2:-}"; shift 2 ;;
      --apps)       filter="apps"; shift ;;
      --libs)       filter="libs"; shift ;;
      --skip-deps)  skip_deps=true; shift ;;
      --dry-run)    dry_run=true; shift ;;
      --continue-on-error) continue_on_error=true; shift ;;
      --help|-h)    affected::help; return 0 ;;
      *)
        mono::error "Unbekannte Option: $1"
        affected::help
        return 1
        ;;
    esac
  done

  if [[ -z "${target}" ]]; then
    mono::error "Kein Target angegeben. Verwende --target <name>"
    affected::help
    return 1
  fi

  # ─── Base-Ref bestimmen ─────────────────────────────────────────────────
  if [[ -z "${base_ref}" ]]; then
    base_ref="${DEPLOY_TAG}"
  fi

  if ! git -C "${MONO_ROOT}" rev-parse --verify "${base_ref}" &>/dev/null; then
    if [[ "${base_ref}" == "${DEPLOY_TAG}" ]]; then
      mono::warn "Deploy-Tag ${BOLD}${base_ref}${NC} existiert noch nicht."
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

  # ─── Graph aufbauen ─────────────────────────────────────────────────────
  graph::build

  # ─── Direkt geänderte Projekte ermitteln ─────────────────────────────────
  local changed_files
  changed_files="$(affected::get_changed_files "${base_ref}")"

  if [[ -z "${changed_files}" ]]; then
    echo ""
    mono::log "Keine Änderungen seit ${BOLD}${base_ref}${NC} (${base_sha})"
    return 0
  fi

  local directly_changed
  directly_changed="$(echo "${changed_files}" | affected::get_directly_changed "${filter}")"

  # ─── Transitive Dependents hinzufügen ───────────────────────────────────
  local all_affected="${directly_changed}"

  while IFS= read -r proj; do
    [[ -z "${proj}" ]] && continue
    local dependents
    dependents="$(graph::transitive_dependents "${proj}" "")"
    if [[ -n "${dependents}" ]]; then
      all_affected="${all_affected}"$'\n'"${dependents}"
    fi
  done <<< "${directly_changed}"

  # Deduplizieren und sortieren
  all_affected="$(echo "${all_affected}" | grep -v '^$' | sort -u)"

  # Filter nochmal anwenden (transitive könnten Apps enthalten bei --libs Filter)
  if [[ "${filter}" != "all" ]]; then
    local filtered=""
    while IFS= read -r proj; do
      [[ -z "${proj}" ]] && continue
      case "${filter}" in
        apps) [[ "${proj}" == apps/* ]] && filtered="${filtered}${proj}"$'\n' ;;
        libs) [[ "${proj}" == libs/* ]] && filtered="${filtered}${proj}"$'\n' ;;
      esac
    done <<< "${all_affected}"
    all_affected="$(echo "${filtered}" | grep -v '^$')"
  fi

  if [[ -z "${all_affected}" ]]; then
    echo ""
    mono::log "Keine betroffenen Projekte seit ${BOLD}${base_ref}${NC} (${base_sha})"
    return 0
  fi

  # ─── Projekte filtern: nur mit dem Target ──────────────────────────────
  local -a matching_projects=()
  local -a skipped_projects=()

  while IFS= read -r proj; do
    [[ -z "${proj}" ]] && continue
    if affected::has_target "${proj}" "${target}"; then
      matching_projects+=("${proj}")
    else
      skipped_projects+=("${proj}")
    fi
  done <<< "${all_affected}"

  if [[ ${#matching_projects[@]} -eq 0 ]]; then
    echo ""
    mono::log "Keine betroffenen Projekte mit Target ${BOLD}${target}${NC}"
    return 0
  fi

  # ─── Topologische Sortierung ───────────────────────────────────────────
  local matching_list=""
  for proj in "${matching_projects[@]}"; do
    matching_list="${matching_list}${proj}"$'\n'
  done

  local sorted_projects
  sorted_projects="$(graph::topo_sort "${matching_list}")" || return 1

  local -a ordered_projects=()
  while IFS= read -r proj; do
    [[ -n "${proj}" ]] && ordered_projects+=("${proj}")
  done <<< "${sorted_projects}"

  # ─── Direkt vs. transitiv markieren ────────────────────────────────────
  local directly_changed_list=",$(echo "${directly_changed}" | tr '\n' ','),"

  # ─── Ausgabe ──────────────────────────────────────────────────────────
  echo ""
  mono::log "Änderungen: ${BOLD}${base_ref}${NC} (${base_sha}) → HEAD (${head_sha})"

  # Zähle direkte und transitive
  local direct_count=0 transitive_count=0
  for proj in "${ordered_projects[@]}"; do
    if [[ "${directly_changed_list}" == *",${proj},"* ]]; then
      direct_count=$((direct_count + 1))
    else
      transitive_count=$((transitive_count + 1))
    fi
  done

  local count_info="${direct_count} direkt"
  [[ ${transitive_count} -gt 0 ]] && count_info="${count_info}, ${transitive_count} transitiv"
  mono::log "Target ${BOLD}${target}${NC} in ${#ordered_projects[@]} Projekt(en) (${count_info})"

  if [[ ${#skipped_projects[@]} -gt 0 ]]; then
    mono::warn "${#skipped_projects[@]} betroffene(s) Projekt(e) übersprungen (Target nicht vorhanden)"
  fi

  if [[ "${dry_run}" == true ]]; then
    echo ""
    echo -e "${BOLD}Ausführungsplan (Reihenfolge):${NC}"
    local i=1
    for proj in "${ordered_projects[@]}"; do
      local name
      name="$(graph::name_of "${proj}")"
      [[ -z "${name}" ]] && name="$(basename "${proj}")"

      local marker=""
      if [[ "${directly_changed_list}" == *",${proj},"* ]]; then
        marker=" ${GREEN}(geändert)${NC}"
      else
        marker=" ${YELLOW}(transitiv)${NC}"
      fi

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
        dep_str=" ← ${dep_names}"
      fi

      echo -e "  ${BOLD}${i}.${NC} ${CYAN}${name}${NC}:${target}${marker}${dep_str}"
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

    local marker=""
    if [[ "${directly_changed_list}" != *",${proj},"* ]]; then
      marker=" ${YELLOW}(transitiv)${NC}"
    fi

    echo ""
    echo -e "${BOLD}━━━ [${current}/${total}] ${CYAN}${name}${NC}${BOLD}:${target}${marker} ━━━${NC}"

    affected::execute_with_deps "${proj}" "${target}" "${skip_deps}" "" || {
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
    mono::log "Alle ${total} betroffenen Projekt(e) erfolgreich ✓"
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
affected::run "$@"
