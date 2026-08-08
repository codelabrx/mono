#!/usr/bin/env bash
# Shared Library: Target-Definitionen aus project.json lesen und ausführen
# Wird von run.sh, run-many.sh und affected.sh per
# `source "${MONO_DIR}/lib/target.sh"` geladen.
#
# Ein Target unterstützt zwei Formen:
#
#   "build": {
#     "command": "bun run build"
#   }
#
#   "applyTerraform": {
#     "commands": [
#       "terraform init",
#       "terraform validate",
#       "terraform plan",
#       "terraform apply -auto-approve"
#     ],
#     "parallel": false
#   }
#
# "commands" (Liste) hat Vorrang vor "command" (Kurzform), falls beide
# gesetzt wären. "parallel": true führt die Liste gleichzeitig statt
# nacheinander aus (Standard: false = sequenziell, Abbruch beim ersten Fehler).

# ─── JSON-Block eines Targets extrahieren (alles zwischen { und }) ─────────
target::block() {
  local file="$1"
  local target="$2"
  sed -n '/"'"${target}"'"[[:space:]]*:[[:space:]]*{/,/}/p' "${file}"
}

# ─── Einzelnen "command"-String lesen (Kurzform) ───────────────────────────
target::single_command() {
  local file="$1"
  local target="$2"

  local block
  block="$(target::block "${file}" "${target}")"
  [[ -z "${block}" ]] && return 1

  echo "${block}" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# ─── Commands eines Targets lesen (zeilenweise, ein Command pro Zeile) ─────
# Unterstützt "command": "..." und "commands": ["...", "..."] (auch mehrzeilig
# formatiert wie im Beispiel oben).
target::commands() {
  local file="$1"
  local target="$2"

  local block
  block="$(target::block "${file}" "${target}")"
  [[ -z "${block}" ]] && return 1

  if echo "${block}" | grep -q '"commands"[[:space:]]*:[[:space:]]*\['; then
    # Ab "commands": [ bis zur schließenden ] extrahieren (ggf. mehrzeilig),
    # den Key selbst entfernen und alle verbleibenden String-Literale lesen.
    echo "${block}" \
      | sed -n '/"commands"[[:space:]]*:[[:space:]]*\[/,/\]/p' \
      | sed 's/"commands"[[:space:]]*:[[:space:]]*\[//' \
      | grep -oE '"[^"]*"' \
      | sed 's/^"//; s/"$//'
  else
    target::single_command "${file}" "${target}"
  fi
}

# ─── "parallel"-Flag eines Targets lesen (Standard: false) ─────────────────
target::is_parallel() {
  local file="$1"
  local target="$2"

  local block
  block="$(target::block "${file}" "${target}")"
  [[ -z "${block}" ]] && return 1

  # Kein \| (BRE-Alternation) – BSD sed (macOS) unterstützt das nicht.
  echo "${block}" | grep -qE '"parallel"[[:space:]]*:[[:space:]]*true'
}

# ─── Anzeige-String für eine Command-Liste ─────────────────────────────────
# Ein Command: unverändert. Mehrere: durch " && " verbunden (nur für Logs).
target::display_string() {
  local commands="$1"
  local joined="" first=true c

  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    if [[ "${first}" == true ]]; then
      joined="${c}"
      first=false
    else
      joined="${joined} && ${c}"
    fi
  done <<< "${commands}"

  echo "${joined}"
}

# ─── Commands ausführen (sequenziell oder parallel) ────────────────────────
# $1: Commands, zeilenweise (Ausgabe von target::commands)
# $2: Arbeitsverzeichnis (cwd)
# $3: "true" für parallele Ausführung, sonst sequenziell (Standard)
#
# Sequenziell wird beim ersten fehlgeschlagenen Command abgebrochen.
# Parallel werden alle Commands gestartet, es wird auf alle gewartet und der
# erste nicht-null Exit-Code zurückgegeben (Logs aller Commands werden
# nacheinander ausgegeben, sobald der jeweilige Command fertig ist).
target::run_commands() {
  local commands="$1"
  local full_dir="$2"
  local run_parallel="${3:-false}"

  local -a cmd_list=()
  local c
  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    cmd_list+=("${c}")
  done <<< "${commands}"

  [[ ${#cmd_list[@]} -eq 0 ]] && return 0

  # Einzelner Command: unverändertes Verhalten, kein zusätzliches Drumherum
  if [[ ${#cmd_list[@]} -eq 1 ]]; then
    (cd "${full_dir}" && eval "${cmd_list[0]}")
    return $?
  fi

  if [[ "${run_parallel}" == "true" ]]; then
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local -a pids=()
    local i=0

    for c in "${cmd_list[@]}"; do
      i=$((i + 1))
      mono::log "  ${YELLOW}▶${NC} ${c} ${YELLOW}(parallel)${NC}"
      (
        (cd "${full_dir}" && eval "${c}") > "${tmp_dir}/${i}.log" 2>&1
        echo $? > "${tmp_dir}/${i}.exit"
      ) &
      pids+=($!)
    done

    for pid in "${pids[@]}"; do
      wait "${pid}" 2>/dev/null || true
    done

    local overall_exit=0
    i=0
    for c in "${cmd_list[@]}"; do
      i=$((i + 1))
      [[ -f "${tmp_dir}/${i}.log" ]] && cat "${tmp_dir}/${i}.log"
      local ec=0
      [[ -f "${tmp_dir}/${i}.exit" ]] && ec="$(cat "${tmp_dir}/${i}.exit")"
      [[ ${ec} -ne 0 && ${overall_exit} -eq 0 ]] && overall_exit=${ec}
    done

    rm -rf "${tmp_dir}"
    return ${overall_exit}
  fi

  # Sequenziell: bei Fehler sofort abbrechen
  for c in "${cmd_list[@]}"; do
    mono::log "  ${YELLOW}▶${NC} ${c}"
    (cd "${full_dir}" && eval "${c}")
    local ec=$?
    [[ ${ec} -ne 0 ]] && return ${ec}
  done

  return 0
}
