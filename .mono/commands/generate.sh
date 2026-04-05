#!/usr/bin/env bash
# description: Generiert neue Apps oder Libs aus Templates

# ─── Subcommand-Routing ────────────────────────────────────────────────────
GENERATE_DIR="${MONO_DIR}/commands/generate"

generate::help() {
  echo ""
  echo -e "${BOLD}mono generate${NC} – Code-Generierung"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono generate <typ> <name> [--template <template>]"
  echo ""
  echo -e "${BOLD}Verfügbare Typen:${NC}"

  if [[ -d "${GENERATE_DIR}" ]]; then
    for f in "${GENERATE_DIR}"/*.sh; do
      [[ -f "$f" ]] || continue
      local name desc
      name="$(basename "${f}" .sh)"
      desc="$(grep -m1 '^# description:' "$f" 2>/dev/null | sed 's/^# description: *//' || echo "")"
      printf "  ${CYAN}%-16s${NC} %s\n" "${name}" "${desc}"
    done
  fi

  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono generate app my-app"
  echo "  mono generate app my-app --template bun"
  echo "  mono generate app backend/my-api --template bun"
  echo ""
}

# ─── Dispatch ───────────────────────────────────────────────────────────────
subcommand="${1:-}"
shift 2>/dev/null || true

if [[ -z "${subcommand}" || "${subcommand}" == "--help" || "${subcommand}" == "-h" ]]; then
  generate::help
  return 0
fi

script="${GENERATE_DIR}/${subcommand}.sh"

if [[ ! -f "${script}" ]]; then
  mono::error "Unbekannter Typ: ${BOLD}${subcommand}${NC}"
  generate::help
  return 1
fi

# shellcheck source=/dev/null
source "${script}" "$@"
