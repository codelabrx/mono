#!/usr/bin/env bash
# description: Fügt ein neues Target zu allen Apps und/oder Libs hinzu

# ─── Help ───────────────────────────────────────────────────────────────────
target::help() {
  echo ""
  echo -e "${BOLD}mono generate target${NC} – Target zu allen Apps/Libs hinzufügen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono generate target --apps --target <name> [optionen]"
  echo "  mono generate target --libs --target <name> [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --apps                  Target in allen apps/**/project.json anlegen"
  echo "  --libs                  Target in allen libs/**/project.json anlegen"
  echo "  --target, -t <name>     Name des Targets (erforderlich)"
  echo "  --command, -c <cmd>     Command des Targets (Standard: interaktive Eingabe)"
  echo "  --depends-on <liste>    Komma-separierte dependsOn-Liste, z. B. install,build"
  echo "  --force                 Vorhandenes Target gleichen Namens überschreiben"
  echo "  --dry-run               Zeigt nur an, was geändert würde"
  echo "  --help, -h              Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono generate target --apps --target format --command \"bun run format\""
  echo "  mono generate target --libs --target lint --command \"bun run lint\" --depends-on install"
  echo "  mono generate target --apps --libs --target ci --command \"bun run ci\" --force"
  echo ""
}

# ─── JSON-Parsing mit reinem sed/grep (analog zu run.sh) ───────────────────
# Kein python3, kein jq, kein gawk – nur POSIX-kompatible Bordmittel.

# Listet die Namen aller bereits vorhandenen Targets einer project.json auf
target::get_existing_names() {
  local file="$1"
  local in_targets=false
  local brace_depth=0

  while IFS= read -r line; do
    local trimmed
    trimmed="$(echo "${line}" | sed 's/^[[:space:]]*//')"

    if [[ "${in_targets}" == false ]]; then
      if echo "${trimmed}" | grep -qE '"targets"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}'; then
        return 0
      fi
      if echo "${trimmed}" | grep -q '"targets"[[:space:]]*:[[:space:]]*{'; then
        in_targets=true
        brace_depth=1
      fi
      continue
    fi

    case "${trimmed}" in
      "}"*|"},"*)
        brace_depth=$((brace_depth - 1))
        [[ ${brace_depth} -le 0 ]] && break
        ;;
    esac

    if [[ ${brace_depth} -eq 1 ]] && echo "${trimmed}" | grep -qE '^"[^"]+"[[:space:]]*:[[:space:]]*\{'; then
      echo "${trimmed}" | sed 's/^"\([^"]*\)".*/\1/'
    fi

    case "${trimmed}" in
      *"{"*) brace_depth=$((brace_depth + 1)) ;;
    esac
  done < "${file}"

  return 0
}

# Gibt den Textblock eines neuen Target-Eintrags aus
target::print_target_block() {
  local indent_key="$1"
  local indent_prop="$2"
  local name="$3"
  local command="$4"
  local depends_on="$5"
  local trailing_comma="$6"

  printf '%s"%s": {\n' "${indent_key}" "${name}"

  if [[ -n "${depends_on}" ]]; then
    printf '%s"command": "%s",\n' "${indent_prop}" "${command}"

    local deps_json="[" first=true d
    IFS=',' read -ra dep_arr <<< "${depends_on}"
    for d in "${dep_arr[@]}"; do
      d="$(echo "${d}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [[ -z "${d}" ]] && continue
      if [[ "${first}" == true ]]; then
        deps_json="${deps_json}\"${d}\""
        first=false
      else
        deps_json="${deps_json}, \"${d}\""
      fi
    done
    deps_json="${deps_json}]"
    printf '%s"dependsOn": %s\n' "${indent_prop}" "${deps_json}"
  else
    printf '%s"command": "%s"\n' "${indent_prop}" "${command}"
  fi

  printf '%s}%s\n' "${indent_key}" "${trailing_comma}"
}

# Schreibt die project.json neu (auf stdout) mit dem eingefügten Target.
# Neue Targets werden immer als erster Eintrag im "targets"-Block eingefügt.
# Existiert das Target bereits (--force), wird der alte Eintrag beim Kopieren
# übersprungen, d. h. effektiv ersetzt.
target::rewrite() {
  local file="$1"
  local name="$2"
  local command="$3"
  local depends_on="$4"
  local exists="$5"
  local trailing_comma="$6"

  local skip_key=""
  [[ "${exists}" == true ]] && skip_key="${name}"

  local in_targets=false
  local skipping=false
  local skip_depth=0
  local inserted=false

  while IFS= read -r line; do
    local trimmed
    trimmed="$(echo "${line}" | sed 's/^[[:space:]]*//')"

    if [[ "${in_targets}" == false ]]; then
      if echo "${trimmed}" | grep -qE '"targets"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}'; then
        local indent="${line%%\"targets\"*}"
        local trail=""
        case "${line}" in *,) trail="," ;; esac

        printf '%s"targets": {\n' "${indent}"
        target::print_target_block "${indent}  " "${indent}    " "${name}" "${command}" "${depends_on}" ""
        printf '%s}%s\n' "${indent}" "${trail}"

        inserted=true
        continue
      fi

      printf '%s\n' "${line}"

      if echo "${trimmed}" | grep -q '"targets"[[:space:]]*:[[:space:]]*{'; then
        in_targets=true
        local indent="${line%%\"targets\"*}"
        target::print_target_block "${indent}  " "${indent}    " "${name}" "${command}" "${depends_on}" "${trailing_comma}"
        inserted=true
      fi
      continue
    fi

    # Bereits im/nach dem "targets"-Block: Rest 1:1 durchreichen,
    # dabei ggf. den alten Eintrag von --force überspringen.
    if [[ "${skipping}" == true ]]; then
      case "${trimmed}" in *"{"*) skip_depth=$((skip_depth + 1)) ;; esac
      case "${trimmed}" in
        "}"*|"},"*)
          skip_depth=$((skip_depth - 1))
          [[ ${skip_depth} -le 0 ]] && skipping=false
          ;;
      esac
      continue
    fi

    if [[ -n "${skip_key}" ]] && echo "${trimmed}" | grep -qE "^\"${skip_key}\"[[:space:]]*:[[:space:]]*\{"; then
      skipping=true
      skip_depth=1
      continue
    fi

    printf '%s\n' "${line}"
  done < "${file}"

  [[ "${inserted}" == true ]]
}

# ─── Ein Projekt verarbeiten ────────────────────────────────────────────────
target::process_project() {
  local project_file="$1"
  local name="$2"
  local command="$3"
  local depends_on="$4"
  local force="$5"
  local dry_run="$6"
  local rel_path="$7"

  if ! grep -q '"targets"' "${project_file}" 2>/dev/null; then
    mono::warn "  ${rel_path}: kein 'targets'-Feld in project.json – überspringe"
    return 1
  fi

  local existing
  existing="$(target::get_existing_names "${project_file}")"

  local exists=false
  if [[ -n "${existing}" ]] && echo "${existing}" | grep -qx "${name}"; then
    exists=true
  fi

  if [[ "${exists}" == true && "${force}" != true ]]; then
    mono::warn "  ${rel_path}: Target '${BOLD}${name}${NC}' existiert bereits – überspringe (--force zum Ersetzen)"
    return 2
  fi

  # Bestimmt, ob nach dem (ggf. force-bedingten) Ersetzen noch weitere
  # Einträge im "targets"-Block übrig bleiben – nur dann braucht der neue
  # Eintrag ein trailendes Komma.
  local remaining
  remaining="$(echo "${existing}" | grep -vx "${name}" || true)"

  local trailing_comma=","
  [[ -z "${remaining}" ]] && trailing_comma=""

  local tmp_file
  tmp_file="$(mktemp)"

  if ! target::rewrite "${project_file}" "${name}" "${command}" "${depends_on}" "${exists}" "${trailing_comma}" > "${tmp_file}"; then
    rm -f "${tmp_file}"
    mono::warn "  ${rel_path}: 'targets'-Block konnte nicht gefunden werden – überspringe"
    return 1
  fi

  if [[ "${dry_run}" == true ]]; then
    local action="hinzugefügt"
    [[ "${exists}" == true ]] && action="ersetzt"
    echo -e "  ${CYAN}${rel_path}${NC} → Target '${name}' würde ${action}"
    rm -f "${tmp_file}"
    return 0
  fi

  mv "${tmp_file}" "${project_file}"

  local action="hinzugefügt"
  [[ "${exists}" == true ]] && action="ersetzt"
  echo -e "  ${GREEN}✓${NC} ${rel_path} (${action})"
  return 0
}

# ─── Hauptfunktion ─────────────────────────────────────────────────────────
target::main() {
  local do_apps=false
  local do_libs=false
  local target_name=""
  local command=""
  local depends_on=""
  local force=false
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apps) do_apps=true; shift ;;
      --libs) do_libs=true; shift ;;
      --target|-t) target_name="${2:-}"; shift 2 ;;
      --command|-c) command="${2:-}"; shift 2 ;;
      --depends-on) depends_on="${2:-}"; shift 2 ;;
      --force) force=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --help|-h) target::help; return 0 ;;
      *)
        mono::error "Unbekanntes Argument: $1"
        target::help
        return 1
        ;;
    esac
  done

  if [[ -z "${target_name}" ]]; then
    mono::error "Kein Target-Name angegeben (--target <name>)"
    target::help
    return 1
  fi

  if [[ "${do_apps}" != true && "${do_libs}" != true ]]; then
    mono::error "Bitte --apps und/oder --libs angeben"
    target::help
    return 1
  fi

  if [[ -z "${command}" ]]; then
    read -rp "Command für Target '${target_name}': " command
    if [[ -z "${command}" ]]; then
      mono::error "Kein Command angegeben"
      return 1
    fi
  fi

  local bases=()
  [[ "${do_apps}" == true ]] && bases+=("apps")
  [[ "${do_libs}" == true ]] && bases+=("libs")

  local total=0
  local updated=0
  local skipped=0
  local failed=0

  echo ""
  if [[ "${dry_run}" == true ]]; then
    mono::log "Dry-Run: Target ${BOLD}${target_name}${NC} → ${command}"
  else
    mono::log "Füge Target ${BOLD}${target_name}${NC} hinzu → ${command}"
  fi

  local base
  for base in "${bases[@]}"; do
    if [[ ! -d "${MONO_ROOT}/${base}" ]]; then
      mono::warn "Verzeichnis ${base}/ existiert nicht – überspringe"
      continue
    fi

    echo ""
    echo -e "${BOLD}${base}/${NC}"

    local project_file
    while IFS= read -r project_file; do
      [[ -z "${project_file}" ]] && continue
      total=$((total + 1))

      local rel_path="${project_file#"${MONO_ROOT}/"}"
      rel_path="$(dirname "${rel_path}")"

      local rc=0
      target::process_project "${project_file}" "${target_name}" "${command}" "${depends_on}" "${force}" "${dry_run}" "${rel_path}" || rc=$?

      case ${rc} in
        0) updated=$((updated + 1)) ;;
        2) skipped=$((skipped + 1)) ;;
        *) failed=$((failed + 1)) ;;
      esac
    done < <(find "${MONO_ROOT}/${base}" -name "project.json" -not -path '*/node_modules/*' | sort)
  done

  echo ""
  mono::log "Fertig: ${GREEN}${updated} aktualisiert${NC}, ${YELLOW}${skipped} übersprungen${NC}, ${RED}${failed} fehlgeschlagen${NC} (von ${total} Projekten)"
  echo ""

  [[ ${failed} -eq 0 ]]
}

# ─── Start ──────────────────────────────────────────────────────────────────
target::main "$@"
