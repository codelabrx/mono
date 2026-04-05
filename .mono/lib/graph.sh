#!/usr/bin/env bash
# Shared Library: Dependency-Graph Funktionen
# Wird von anderen Commands per `source "${MONO_DIR}/lib/graph.sh"` geladen.

# ─── JSON-Feld lesen (standalone) ──────────────────────────────────────────
graph::json_field() {
  local file="$1"
  local field="$2"
  sed -n 's/.*"'"${field}"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${file}" | head -1
}

# ─── Dependencies aus project.json lesen ───────────────────────────────────
# Liest das "dependencies"-Array und gibt Einträge zeilenweise aus.
# Format in project.json: "dependencies": ["lib-a", "lib-b"]
graph::get_dependencies() {
  local project_file="$1"

  [[ -f "${project_file}" ]] || return 0

  local deps_line
  deps_line="$(grep '"dependencies"' "${project_file}" | head -1)"
  [[ -z "${deps_line}" ]] && return 0

  # Leeres Array erkennen
  if echo "${deps_line}" | grep -q '\[\s*\]'; then
    return 0
  fi

  echo "${deps_line}" | sed 's/.*\[//; s/\].*//' | tr ',' '\n' | sed 's/[[:space:]]*"//g; /^$/d'
}

# ─── Alle Projekte mit project.json finden ──────────────────────────────────
graph::find_all_projects() {
  for dir in "${MONO_ROOT}/apps" "${MONO_ROOT}/libs"; do
    [[ -d "${dir}" ]] || continue
    while IFS= read -r -d '' pjson; do
      local proj_dir
      proj_dir="$(dirname "${pjson}")"
      echo "${proj_dir#"${MONO_ROOT}/"}"
    done < <(find "${dir}" -name "project.json" -print0 2>/dev/null)
  done | sort
}

# ─── Projektname → Pfad auflösen ──────────────────────────────────────────
graph::resolve_project() {
  local name="$1"

  # Direkt als Pfad prüfen
  for base in apps libs; do
    if [[ -f "${MONO_ROOT}/${base}/${name}/project.json" ]]; then
      echo "${base}/${name}"
      return 0
    fi
  done

  # Nach Name in project.json suchen
  while IFS= read -r -d '' pjson; do
    local pname
    pname="$(graph::json_field "${pjson}" "name")"
    if [[ "${pname}" == "${name}" ]]; then
      local pdir
      pdir="$(dirname "${pjson}")"
      echo "${pdir#"${MONO_ROOT}/"}"
      return 0
    fi
  done < <(find "${MONO_ROOT}/apps" "${MONO_ROOT}/libs" -name "project.json" -print0 2>/dev/null)

  return 1
}

# ─── Dependency-Graph aufbauen ─────────────────────────────────────────────
# Speichert den Graph in Variablen:
#   _GRAPH_NODES  – alle Projekt-Pfade (zeilenweise)
#   _GRAPH_EDGES  – Kanten als "from→to" (zeilenweise)
#   _GRAPH_NAMES  – "pfad=name" Mapping (zeilenweise)
#
# Muss vor graph::topo_sort / graph::dependents aufgerufen werden.
graph::build() {
  _GRAPH_NODES=""
  _GRAPH_EDGES=""
  _GRAPH_NAMES=""

  local all_projects
  all_projects="$(graph::find_all_projects)"

  while IFS= read -r proj; do
    [[ -z "${proj}" ]] && continue
    local pjson="${MONO_ROOT}/${proj}/project.json"

    local name
    name="$(graph::json_field "${pjson}" "name")"
    [[ -z "${name}" ]] && name="$(basename "${proj}")"

    _GRAPH_NODES="${_GRAPH_NODES}${proj}"$'\n'
    _GRAPH_NAMES="${_GRAPH_NAMES}${proj}=${name}"$'\n'

    # Dependencies auflösen
    local deps
    deps="$(graph::get_dependencies "${pjson}")"

    while IFS= read -r dep; do
      [[ -z "${dep}" ]] && continue
      local dep_path
      dep_path="$(graph::resolve_project "${dep}")" || {
        mono::warn "Dependency ${BOLD}${dep}${NC} von ${BOLD}${name}${NC} nicht gefunden"
        continue
      }
      _GRAPH_EDGES="${_GRAPH_EDGES}${proj}→${dep_path}"$'\n'
    done <<< "${deps}"
  done <<< "${all_projects}"
}

# ─── Projektname aus Graph lesen ───────────────────────────────────────────
graph::name_of() {
  local path="$1"
  echo "${_GRAPH_NAMES}" | grep "^${path}=" | head -1 | cut -d= -f2-
}

# ─── Direkte Dependencies eines Projekts ──────────────────────────────────
graph::deps_of() {
  local path="$1"
  echo "${_GRAPH_EDGES}" | grep "^${path}→" | sed 's/.*→//' | grep -v '^$' || true
}

# ─── Alle Projekte die von einem Projekt abhängen (direkt) ────────────────
graph::dependents_of() {
  local path="$1"
  echo "${_GRAPH_EDGES}" | grep "→${path}$" | sed 's/→.*//' | grep -v '^$' || true
}

# ─── Transitive Dependents (wer ist alles betroffen?) ─────────────────────
# Gibt alle Projekte aus, die direkt oder transitiv von `path` abhängen.
graph::transitive_dependents() {
  local path="$1"
  local _visited="$2"

  local directs
  directs="$(graph::dependents_of "${path}")"

  while IFS= read -r dep; do
    [[ -z "${dep}" ]] && continue
    # Bereits besucht?
    if [[ ",${_visited}," == *",${dep},"* ]]; then
      continue
    fi
    _visited="${_visited:+${_visited},}${dep}"
    echo "${dep}"
    # Rekursiv
    local transitive
    transitive="$(graph::transitive_dependents "${dep}" "${_visited}")"
    if [[ -n "${transitive}" ]]; then
      echo "${transitive}"
      # Visited erweitern
      while IFS= read -r t; do
        [[ -n "${t}" ]] && _visited="${_visited},${t}"
      done <<< "${transitive}"
    fi
  done <<< "${directs}"
}

# ─── Transitive Dependencies (was braucht ein Projekt alles?) ─────────────
graph::transitive_deps() {
  local path="$1"
  local _visited="$2"

  local directs
  directs="$(graph::deps_of "${path}")"

  while IFS= read -r dep; do
    [[ -z "${dep}" ]] && continue
    if [[ ",${_visited}," == *",${dep},"* ]]; then
      continue
    fi
    _visited="${_visited:+${_visited},}${dep}"
    echo "${dep}"
    local transitive
    transitive="$(graph::transitive_deps "${dep}" "${_visited}")"
    if [[ -n "${transitive}" ]]; then
      echo "${transitive}"
      while IFS= read -r t; do
        [[ -n "${t}" ]] && _visited="${_visited},${t}"
      done <<< "${transitive}"
    fi
  done <<< "${directs}"
}

# ─── Topologische Sortierung (Kahn's Algorithm) ───────────────────────────
# Gibt die Projekte in Build-Reihenfolge aus (Dependencies zuerst).
# Bei Zyklen wird ein Fehler ausgegeben.
# Kompatibel mit Bash 3.2 (kein declare -A).
graph::topo_sort() {
  local filter_list="$1"  # Optional: nur diese Projekte (zeilenweise), leer = alle

  local nodes
  if [[ -n "${filter_list}" ]]; then
    nodes="${filter_list}"
  else
    nodes="${_GRAPH_NODES}"
  fi

  # Knotenliste als Array
  local all_nodes=""
  local node_count=0
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    all_nodes="${all_nodes}${node}"$'\n'
    node_count=$((node_count + 1))
  done <<< "${nodes}"

  # In-Degree berechnen: für jeden Knoten zählen wir eingehende Kanten
  # Kante "from→to" bedeutet "from hängt von to ab", also muss to VOR from kommen.
  # In-Degree = Anzahl Dependencies (= Anzahl Kanten FROM diesem Knoten)
  local in_degrees=""
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    local degree=0
    while IFS= read -r edge; do
      [[ -z "${edge}" ]] && continue
      local from="${edge%%→*}"
      local to="${edge##*→}"
      # from→to: from hängt von to ab. from hat eine Dependency.
      # In-Degree von from erhöhen wenn diese Kante relevant ist.
      if [[ "${from}" == "${node}" ]] && echo "${all_nodes}" | grep -q "^${to}$"; then
        degree=$((degree + 1))
      fi
    done <<< "${_GRAPH_EDGES}"
    in_degrees="${in_degrees}${node}=${degree}"$'\n'
  done <<< "${all_nodes}"

  # Iterativ: Knoten mit In-Degree 0 finden, ausgeben, Kanten entfernen
  local sorted=""
  local count=0
  local remaining="${all_nodes}"

  while [[ ${count} -lt ${node_count} ]]; do
    local found_any=false

    # Knoten mit In-Degree 0 suchen
    local next_remaining=""
    local batch=""

    while IFS= read -r node; do
      [[ -z "${node}" ]] && continue
      local degree
      degree="$(echo "${in_degrees}" | grep "^${node}=" | head -1 | cut -d= -f2)"
      [[ -z "${degree}" ]] && degree=0

      if [[ ${degree} -eq 0 ]]; then
        batch="${batch}${node}"$'\n'
        found_any=true
      else
        next_remaining="${next_remaining}${node}"$'\n'
      fi
    done <<< "${remaining}"

    if [[ "${found_any}" != true ]]; then
      # Zyklus erkannt
      mono::error "Zyklische Abhängigkeit erkannt!"
      echo ""
      while IFS= read -r node; do
        [[ -z "${node}" ]] && continue
        local name
        name="$(graph::name_of "${node}")"
        mono::error "  ↻ ${name} (${node})"
      done <<< "${remaining}"
      return 1
    fi

    # Batch zur Ausgabe hinzufügen
    sorted="${sorted}${batch}"
    count=$((count + $(echo "${batch}" | grep -c -v '^$')))

    # In-Degrees aktualisieren: Kanten zu Batch-Knoten entfernen
    while IFS= read -r processed; do
      [[ -z "${processed}" ]] && continue
      # Alle Dependents finden (Kanten X → processed, also X hängt von processed ab)
      while IFS= read -r edge; do
        [[ -z "${edge}" ]] && continue
        local from="${edge%%→*}"
        local to="${edge##*→}"
        if [[ "${to}" == "${processed}" ]]; then
          # In-Degree von 'from' verringern (from hat eine Dependency weniger)
          local old_degree
          old_degree="$(echo "${in_degrees}" | grep "^${from}=" | head -1 | cut -d= -f2)"
          [[ -z "${old_degree}" ]] && continue
          local new_degree=$((old_degree - 1))
          in_degrees="$(echo "${in_degrees}" | sed "s|^${from}=${old_degree}$|${from}=${new_degree}|")"
        fi
      done <<< "${_GRAPH_EDGES}"
    done <<< "${batch}"

    remaining="${next_remaining}"
  done

  # Ausgabe
  echo "${sorted}" | grep -v '^$'
}

# ─── Graph als Text-Baum ausgeben ─────────────────────────────────────────
graph::print_tree() {
  local nodes="${_GRAPH_NODES}"

  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    local name
    name="$(graph::name_of "${node}")"
    local type_icon=""
    [[ "${node}" == apps/* ]] && type_icon="📦"
    [[ "${node}" == libs/* ]] && type_icon="📚"

    local deps
    deps="$(graph::deps_of "${node}")"

    if [[ -z "${deps}" ]]; then
      echo -e "  ${type_icon} ${CYAN}${name}${NC} (${node})"
    else
      echo -e "  ${type_icon} ${CYAN}${name}${NC} (${node})"
      while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        local dep_name
        dep_name="$(graph::name_of "${dep}")"
        echo -e "     └─ ${YELLOW}${dep_name}${NC} (${dep})"
      done <<< "${deps}"
    fi
  done <<< "${nodes}"
}
