#!/usr/bin/env bash
# description: Führt Targets aus der project.json einer App/Lib aus

# Graph-Library laden
source "${MONO_DIR}/lib/graph.sh"
# Cache-Library laden
source "${MONO_DIR}/lib/cache.sh"
# Target-Library laden (Command-Parsing & Ausführung)
source "${MONO_DIR}/lib/target.sh"

# ─── Help ───────────────────────────────────────────────────────────────────
run::help() {
  echo ""
  echo -e "${BOLD}mono run${NC} – Targets ausführen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono run <projekt>:<target>"
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono run my-app:dev           # Führt das 'dev' Target von my-app aus"
  echo "  mono run my-app:build         # Führt 'build' aus (inkl. dependsOn-Kette)"
  echo "  mono run my-app:test          # Führt 'test' aus"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --skip-deps          dependsOn-Kette überspringen"
  echo "  --skip-project-deps  Cross-Project Dependencies überspringen"
  echo "  --no-cache            Caching deaktivieren"
  echo "  --dry-run             Zeigt was ausgeführt würde, ohne es zu tun"
  echo "  --list                Alle Targets eines Projekts auflisten"
  echo "  --help, -h            Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Targets${NC} werden in der ${CYAN}project.json${NC} des Projekts definiert:"
  echo ""
  echo '  "targets": {'
  echo '    "dev": {'
  echo '      "command": "bun run --watch src/index.ts",'
  echo '      "dependsOn": ["install"]'
  echo '    },'
  echo '    "applyTerraform": {'
  echo '      "commands": ['
  echo '        "terraform init",'
  echo '        "terraform validate",'
  echo '        "terraform plan",'
  echo '        "terraform apply -auto-approve"'
  echo '      ],'
  echo '      "parallel": false'
  echo '    }'
  echo '  }'
  echo ""
  echo -e "  Statt eines einzelnen ${CYAN}command${NC} kann ein Target auch eine Liste"
  echo -e "  ${CYAN}commands${NC} definieren. ${CYAN}parallel${NC} steuert, ob diese Liste"
  echo "  nacheinander (false, Standard) oder gleichzeitig (true) läuft."
  echo ""
}

# ─── JSON-Parsing mit reinem sed/grep ──────────────────────────────────────
# Kein python3, kein jq, kein gawk – nur POSIX-kompatible Bordmittel.
# Funktioniert mit der vorhersagbaren Struktur unserer project.json.

# Liest den Wert eines Top-Level String-Feldes: "name": "value"
run::json_field() {
  local file="$1"
  local field="$2"
  sed -n 's/.*"'"${field}"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${file}" | head -1
}

# Extrahiert den JSON-Block eines Targets (alles zwischen { und })
# Gibt den rohen Block als Text aus.
run::target_block() {
  local file="$1"
  local target="$2"

  # Finde die Zeile "TARGET": { und lese bis zur schließenden }
  sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${file}"
}

# Liest den Command eines Targets
run::get_target_command() {
  local file="$1"
  local target="$2"

  # Zuerst den target-Block extrahieren, dann command darin finden
  local block
  block="$(run::target_block "${file}" "${target}")"
  [[ -z "${block}" ]] && return 1

  echo "${block}" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Liest die dependsOn eines Targets (eine Dependency pro Zeile)
run::get_target_deps() {
  local file="$1"
  local target="$2"

  local block
  block="$(run::target_block "${file}" "${target}")"
  [[ -z "${block}" ]] && return 0

  # dependsOn-Zeile finden und Array-Elemente extrahieren
  # Format: "dependsOn": ["install", "build"]
  local deps_line
  deps_line="$(echo "${block}" | grep '"dependsOn"' | head -1)"
  [[ -z "${deps_line}" ]] && return 0

  # Alle "xxx" Werte aus dem Array extrahieren
  echo "${deps_line}" | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | sed 's/[[:space:]]*"//g; /^$/d'
}

# Listet alle Target-Namen auf
run::get_target_names() {
  local file="$1"

  # Alles innerhalb des "targets": { ... } Blocks finden
  # Dann Keys finden, die ein { öffnen (= Target-Objekte)
  local in_targets=false
  local brace_depth=0

  while IFS= read -r line; do
    # Whitespace trimmen
    local trimmed
    trimmed="$(echo "${line}" | sed 's/^[[:space:]]*//')"

    if [[ "${in_targets}" == false ]]; then
      # Start des targets-Blocks suchen
      if echo "${trimmed}" | grep -q '"targets"[[:space:]]*:[[:space:]]*{'; then
        in_targets=true
        brace_depth=1
      fi
      continue
    fi

    # Innerhalb von targets
    # Schließende Klammern zählen
    case "${trimmed}" in
      "}"*|"},"*)
        brace_depth=$((brace_depth - 1))
        [[ ${brace_depth} -le 0 ]] && break
        ;;
    esac

    # Auf Tiefe 1: Keys die neue Objekte öffnen = Target-Namen
    if [[ ${brace_depth} -eq 1 ]] && echo "${trimmed}" | grep -q '"[^"]*"[[:space:]]*:[[:space:]]*{'; then
      echo "${trimmed}" | sed 's/.*"\([^"]*\)"[[:space:]]*:.*/\1/'
    fi

    # Öffnende Klammern zählen
    case "${trimmed}" in
      *"{"*) brace_depth=$((brace_depth + 1)) ;;
    esac
  done < "${file}"
}

# ─── Projekt-Verzeichnis finden ─────────────────────────────────────────────
run::find_project() {
  local name="$1"

  # Direkt als Pfad prüfen (apps/name oder libs/name)
  for base in apps libs; do
    if [[ -f "${MONO_ROOT}/${base}/${name}/project.json" ]]; then
      echo "${base}/${name}"
      return 0
    fi
  done

  # Nach Name in project.json suchen (rekursiv)
  local found=""
  while IFS= read -r -d '' pjson; do
    local proj_name
    proj_name="$(run::json_field "${pjson}" "name")"
    if [[ "${proj_name}" == "${name}" ]]; then
      local dir
      dir="$(dirname "${pjson}")"
      found="${dir#"${MONO_ROOT}/"}"
      break
    fi
  done < <(find "${MONO_ROOT}/apps" "${MONO_ROOT}/libs" -name "project.json" -print0 2>/dev/null)

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return 0
  fi

  return 1
}

# ─── Targets auflisten ─────────────────────────────────────────────────────
run::list_targets() {
  local project_dir="$1"
  local project_file="${MONO_ROOT}/${project_dir}/project.json"

  local proj_name
  proj_name="$(run::json_field "${project_file}" "name")"
  [[ -z "${proj_name}" ]] && proj_name="$(basename "${project_dir}")"

  echo ""
  echo -e "${BOLD}Targets für ${CYAN}${proj_name}${NC} ${BOLD}(${project_dir})${NC}"
  echo ""

  local targets
  targets="$(run::get_target_names "${project_file}")"

  if [[ -z "${targets}" ]]; then
    echo "  (keine Targets definiert)"
    echo ""
    return 0
  fi

  while IFS= read -r target_name; do
    [[ -z "${target_name}" ]] && continue

    local cmds cmd_count cmd deps_list
    cmds="$(target::commands "${project_file}" "${target_name}")"
    cmd_count="$(echo "${cmds}" | grep -c -v '^$')"
    cmd="$(target::display_string "${cmds}")"
    [[ ${cmd_count} -gt 1 ]] && cmd="${cmd} (${cmd_count} commands)"
    deps_list="$(run::get_target_deps "${project_file}" "${target_name}" | tr '\n' ', ' | sed 's/, *$//')"

    local deps_str=""
    [[ -n "${deps_list}" ]] && deps_str=" → ${deps_list}"

    printf "  ${CYAN}%-16s${NC} %s${YELLOW}%s${NC}\n" "${target_name}" "${cmd}" "${deps_str}"
  done <<< "${targets}"

  echo ""
}

# ─── Target ausführen (mit dependsOn-Auflösung) ────────────────────────────
run::execute_target() {
  local project_dir="$1"
  local target="$2"
  local skip_deps="$3"
  local dry_run="$4"
  local _executed="$5"  # Bereits ausgeführte Targets (komma-separiert)
  local skip_project_deps="${6:-false}"
  local _executed_projects="${7:-}"  # Bereits ausgeführte Projekte (komma-separiert)
  local no_cache="${8:-false}"

  local project_file="${MONO_ROOT}/${project_dir}/project.json"
  local full_dir="${MONO_ROOT}/${project_dir}"

  # ─── Cross-Project Dependencies zuerst ausführen ────────────────────────
  if [[ "${skip_project_deps}" != "true" ]]; then
    local proj_deps
    proj_deps="$(graph::get_dependencies "${project_file}")"

    if [[ -n "${proj_deps}" ]]; then
      while IFS= read -r dep_name; do
        [[ -z "${dep_name}" ]] && continue

        # Bereits ausgeführtes Projekt überspringen
        if [[ ",${_executed_projects}," == *",${dep_name},"* ]]; then
          continue
        fi

        local dep_dir
        dep_dir="$(graph::resolve_project "${dep_name}")" || {
          mono::warn "Dependency ${BOLD}${dep_name}${NC} nicht gefunden – überspringe"
          continue
        }

        local dep_project_file="${MONO_ROOT}/${dep_dir}/project.json"

        # Prüfen ob das Target in der Dependency existiert
        local dep_has_target
        dep_has_target="$(sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${dep_project_file}" | head -1)"

        if [[ -n "${dep_has_target}" ]]; then
          if [[ "${dry_run}" == "true" ]]; then
            echo -e "  ${YELLOW}[dep]${NC} ${CYAN}${dep_name}:${target}${NC} (${dep_dir})"
          else
            mono::log "${YELLOW}[dep]${NC} ${BOLD}${dep_name}:${target}${NC}"
          fi

          run::execute_target "${dep_dir}" "${target}" "${skip_deps}" "${dry_run}" "" "${skip_project_deps}" "${_executed_projects}" "${no_cache}" || return 1
          _executed_projects="${_executed_projects:+${_executed_projects},}${dep_name}"
        fi
      done <<< "${proj_deps}"
    fi
  fi

  # Prüfen ob Target bereits ausgeführt
  if [[ ",${_executed}," == *",${target},"* ]]; then
    return 0
  fi

  # Commands lesen (Kurzform "command" oder Liste "commands")
  local commands
  commands="$(target::commands "${project_file}" "${target}")"
  if [[ -z "${commands}" ]]; then
    mono::error "Target ${BOLD}${target}${NC} nicht gefunden in ${project_dir}/project.json"
    return 1
  fi

  local command_count
  command_count="$(echo "${commands}" | grep -c -v '^$')"

  local run_parallel=false
  target::is_parallel "${project_file}" "${target}" && run_parallel=true

  local command_display
  command_display="$(target::display_string "${commands}")"

  # DependsOn auflösen
  if [[ "${skip_deps}" != "true" ]]; then
    local deps
    deps="$(run::get_target_deps "${project_file}" "${target}")"

    if [[ -n "${deps}" ]]; then
      while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        run::execute_target "${project_dir}" "${dep}" "${skip_deps}" "${dry_run}" "${_executed}" "${skip_project_deps}" "${_executed_projects}" "${no_cache}" || return 1
        _executed="${_executed:+${_executed},}${dep}"
      done <<< "${deps}"
    fi
  fi

  # Projektname lesen
  local proj_name
  proj_name="$(run::json_field "${project_file}" "name")"
  [[ -z "${proj_name}" ]] && proj_name="$(basename "${project_dir}")"

  # ─── Cache-Check ──────────────────────────────────────────────────────
  local use_cache=false
  local input_hash=""

  if [[ "${no_cache}" != "true" && "${dry_run}" != "true" ]]; then
    if cache::is_cacheable "${project_file}" "${target}"; then
      use_cache=true
      input_hash="$(cache::compute_hash "${project_dir}" "${target}" "${commands}")"

      if cache::check "${project_dir}" "${target}" "${input_hash}"; then
        mono::log "${BOLD}${proj_name}:${target}${NC} ${GREEN}[cache hit]${NC} ✓"
        cache::restore_outputs "${project_dir}" "${target}" "${input_hash}" 2>/dev/null || true
        return 0
      fi
    fi
  fi

  local mode_suffix=""
  if [[ ${command_count} -gt 1 ]]; then
    mode_suffix=" ${YELLOW}(${command_count} commands, $([[ "${run_parallel}" == true ]] && echo "parallel" || echo "sequenziell"))${NC}"
  fi

  if [[ "${dry_run}" == "true" ]]; then
    echo -e "  ${CYAN}${proj_name}:${target}${NC} → ${command_display}${mode_suffix}"
    echo -e "    ${YELLOW}(cwd: ${project_dir})${NC}"
  else
    echo ""
    mono::log "${BOLD}${proj_name}:${target}${NC} → ${command_display}${mode_suffix}"
    mono::log "cwd: ${project_dir}"
    echo ""

    target::run_commands "${commands}" "${full_dir}" "${run_parallel}"
    local exit_code=$?

    if [[ ${exit_code} -ne 0 ]]; then
      mono::error "Target ${BOLD}${target}${NC} fehlgeschlagen (Exit: ${exit_code})"
      return ${exit_code}
    fi

    # Cache speichern
    if [[ "${use_cache}" == true && -n "${input_hash}" ]]; then
      cache::save "${project_dir}" "${target}" "${input_hash}" "${commands}"
      cache::cleanup_target "${project_dir}" "${target}" "${input_hash}"
    fi

    mono::log "Target ${BOLD}${target}${NC} abgeschlossen ✓"
  fi

  return 0
}

# ─── Hauptfunktion ─────────────────────────────────────────────────────────
run::main() {
  local input=""
  local skip_deps=false
  local skip_project_deps=false
  local no_cache=false
  local dry_run=false
  local list_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-deps)  skip_deps=true; shift ;;
      --skip-project-deps) skip_project_deps=true; shift ;;
      --no-cache)   no_cache=true; shift ;;
      --dry-run)    dry_run=true; shift ;;
      --list)       list_mode=true; shift ;;
      --help|-h)    run::help; return 0 ;;
      -*)
        mono::error "Unbekannte Option: $1"
        run::help
        return 1
        ;;
      *)
        if [[ -z "${input}" ]]; then
          input="$1"
        else
          mono::error "Unerwartetes Argument: $1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${input}" ]]; then
    mono::error "Kein Projekt angegeben"
    run::help
    return 1
  fi

  local project_name=""
  local target=""

  if [[ "${input}" == *:* ]]; then
    project_name="${input%%:*}"
    target="${input#*:}"
  else
    project_name="${input}"
  fi

  local project_dir
  project_dir="$(run::find_project "${project_name}")" || {
    mono::error "Projekt nicht gefunden: ${BOLD}${project_name}${NC}"
    echo ""
    mono::warn "Suche in apps/ und libs/ nach einem Verzeichnis oder project.json mit diesem Namen."
    return 1
  }

  local project_file="${MONO_ROOT}/${project_dir}/project.json"

  if [[ ! -f "${project_file}" ]]; then
    mono::error "Keine project.json in ${project_dir}"
    return 1
  fi

  if [[ "${list_mode}" == true || -z "${target}" ]]; then
    run::list_targets "${project_dir}"
    return 0
  fi

  if [[ "${dry_run}" == true ]]; then
    echo ""
    mono::log "Dry-Run: ${BOLD}${project_name}:${target}${NC}"
    echo ""
  fi

  run::execute_target "${project_dir}" "${target}" "${skip_deps}" "${dry_run}" "" "${skip_project_deps}" "" "${no_cache}"
}

# ─── Start ──────────────────────────────────────────────────────────────────
run::main "$@"
