#!/usr/bin/env bash
# description: Zeigt den Dependency-Graph aller Projekte

# Graph-Library laden
source "${MONO_DIR}/lib/graph.sh"

# ─── Help ───────────────────────────────────────────────────────────────────
graph_cmd::help() {
  echo ""
  echo -e "${BOLD}mono graph${NC} – Dependency-Graph anzeigen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono graph [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --project, -p <name>  Graph für ein einzelnes Projekt"
  echo "  --json                Ausgabe als JSON"
  echo "  --order               Topologische Build-Reihenfolge anzeigen"
  echo "  --help, -h            Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono graph                         # Gesamter Graph"
  echo "  mono graph --project my-app        # Dependencies von my-app"
  echo "  mono graph --order                 # Build-Reihenfolge"
  echo "  mono graph --json                  # JSON-Ausgabe"
  echo ""
}

# ─── Graph für ein einzelnes Projekt ───────────────────────────────────────
graph_cmd::show_project() {
  local project_name="$1"

  local project_dir
  project_dir="$(graph::resolve_project "${project_name}")" || {
    mono::error "Projekt nicht gefunden: ${BOLD}${project_name}${NC}"
    return 1
  }

  local name
  name="$(graph::name_of "${project_dir}")"
  [[ -z "${name}" ]] && name="${project_name}"

  echo ""
  echo -e "${BOLD}Dependency-Graph für ${CYAN}${name}${NC} ${BOLD}(${project_dir})${NC}"

  # Dependencies
  local deps
  deps="$(graph::deps_of "${project_dir}")"

  echo ""
  echo -e "${BOLD}  Dependencies (braucht):${NC}"
  if [[ -z "${deps}" ]]; then
    echo "    (keine)"
  else
    while IFS= read -r dep; do
      [[ -z "${dep}" ]] && continue
      local dep_name
      dep_name="$(graph::name_of "${dep}")"
      echo -e "    └─ ${CYAN}${dep_name}${NC} (${dep})"
    done <<< "${deps}"

    # Transitive
    local trans_deps
    trans_deps="$(graph::transitive_deps "${project_dir}" "")"
    local extra=""
    while IFS= read -r td; do
      [[ -z "${td}" ]] && continue
      # Nur transitive (nicht direkte)
      if ! echo "${deps}" | grep -q "^${td}$"; then
        local td_name
        td_name="$(graph::name_of "${td}")"
        extra="${extra}    └─ ${YELLOW}${td_name}${NC} (${td}) [transitiv]\n"
      fi
    done <<< "${trans_deps}"
    [[ -n "${extra}" ]] && echo -e "${extra}"
  fi

  # Dependents
  local dependents
  dependents="$(graph::dependents_of "${project_dir}")"

  echo -e "${BOLD}  Dependents (wird gebraucht von):${NC}"
  if [[ -z "${dependents}" ]]; then
    echo "    (keine)"
  else
    while IFS= read -r dep; do
      [[ -z "${dep}" ]] && continue
      local dep_name
      dep_name="$(graph::name_of "${dep}")"
      echo -e "    └─ ${CYAN}${dep_name}${NC} (${dep})"
    done <<< "${dependents}"

    # Transitive
    local trans_dependents
    trans_dependents="$(graph::transitive_dependents "${project_dir}" "")"
    while IFS= read -r td; do
      [[ -z "${td}" ]] && continue
      if ! echo "${dependents}" | grep -q "^${td}$"; then
        local td_name
        td_name="$(graph::name_of "${td}")"
        echo -e "    └─ ${YELLOW}${td_name}${NC} (${td}) [transitiv]"
      fi
    done <<< "${trans_dependents}"
  fi

  echo ""
}

# ─── JSON-Ausgabe ──────────────────────────────────────────────────────────
graph_cmd::json() {
  local nodes_json=""
  local edges_json=""

  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    local name
    name="$(graph::name_of "${node}")"

    local type="other"
    [[ "${node}" == apps/* ]] && type="app"
    [[ "${node}" == libs/* ]] && type="lib"

    local deps_arr=""
    local deps
    deps="$(graph::deps_of "${node}")"
    while IFS= read -r dep; do
      [[ -z "${dep}" ]] && continue
      local dep_name
      dep_name="$(graph::name_of "${dep}")"
      [[ -n "${deps_arr}" ]] && deps_arr="${deps_arr},"
      deps_arr="${deps_arr}\"${dep_name}\""
    done <<< "${deps}"

    [[ -n "${nodes_json}" ]] && nodes_json="${nodes_json},"
    nodes_json="${nodes_json}{\"name\":\"${name}\",\"path\":\"${node}\",\"type\":\"${type}\",\"dependencies\":[${deps_arr}]}"
  done <<< "${_GRAPH_NODES}"

  # Kanten
  while IFS= read -r edge; do
    [[ -z "${edge}" ]] && continue
    local from="${edge%%→*}"
    local to="${edge##*→}"
    local from_name to_name
    from_name="$(graph::name_of "${from}")"
    to_name="$(graph::name_of "${to}")"

    [[ -n "${edges_json}" ]] && edges_json="${edges_json},"
    edges_json="${edges_json}{\"from\":\"${from_name}\",\"to\":\"${to_name}\"}"
  done <<< "${_GRAPH_EDGES}"

  echo "{\"nodes\":[${nodes_json}],\"edges\":[${edges_json}]}"
}

# ─── Hauptfunktion ─────────────────────────────────────────────────────────
graph_cmd::run() {
  local project=""
  local output="pretty"
  local show_order=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p) project="${2:-}"; shift 2 ;;
      --json)       output="json"; shift ;;
      --order)      show_order=true; shift ;;
      --help|-h)    graph_cmd::help; return 0 ;;
      *)
        mono::error "Unbekannte Option: $1"
        graph_cmd::help
        return 1
        ;;
    esac
  done

  # Graph aufbauen
  graph::build

  # JSON-Ausgabe
  if [[ "${output}" == "json" ]]; then
    graph_cmd::json
    return 0
  fi

  # Einzelprojekt
  if [[ -n "${project}" ]]; then
    graph_cmd::show_project "${project}"
    return $?
  fi

  # Build-Reihenfolge
  if [[ "${show_order}" == true ]]; then
    echo ""
    echo -e "${BOLD}Topologische Build-Reihenfolge:${NC}"
    echo ""

    local sorted
    sorted="$(graph::topo_sort "")" || return 1

    if [[ -z "${sorted}" ]]; then
      echo "  (keine Projekte gefunden)"
    else
      local i=1
      while IFS= read -r proj; do
        [[ -z "${proj}" ]] && continue
        local name
        name="$(graph::name_of "${proj}")"
        local type_icon=""
        [[ "${proj}" == apps/* ]] && type_icon="📦"
        [[ "${proj}" == libs/* ]] && type_icon="📚"

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

        echo -e "  ${BOLD}${i}.${NC} ${type_icon} ${CYAN}${name}${NC} (${proj})${dep_str}"
        ((i++))
      done <<< "${sorted}"
    fi

    echo ""
    return 0
  fi

  # ─── Gesamter Graph ──────────────────────────────────────────────────
  echo ""
  echo -e "${BOLD}Dependency-Graph${NC}"
  echo ""

  local nodes="${_GRAPH_NODES}"
  local edges="${_GRAPH_EDGES}"

  if [[ -z "$(echo "${nodes}" | grep -v '^$')" ]]; then
    echo "  (keine Projekte gefunden)"
    echo ""
    return 0
  fi

  # Statistik
  local node_count=0 edge_count=0 app_count=0 lib_count=0
  while IFS= read -r n; do
    [[ -z "${n}" ]] && continue
    node_count=$((node_count + 1))
    [[ "${n}" == apps/* ]] && app_count=$((app_count + 1))
    [[ "${n}" == libs/* ]] && lib_count=$((lib_count + 1))
  done <<< "${nodes}"

  while IFS= read -r e; do
    [[ -z "${e}" ]] && continue
    edge_count=$((edge_count + 1))
  done <<< "${edges}"

  echo -e "  ${BOLD}Projekte:${NC} ${node_count} (${app_count} Apps, ${lib_count} Libs)"
  echo -e "  ${BOLD}Abhängigkeiten:${NC} ${edge_count}"
  echo ""

  # Graph anzeigen
  graph::print_tree

  echo ""
}

# ─── Start ──────────────────────────────────────────────────────────────────
graph_cmd::run "$@"
