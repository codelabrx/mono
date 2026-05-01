#!/usr/bin/env bash
# description: Setzt die Deploy-Ref auf den aktuellen Commit

DEPLOY_REF="${MONO_DEPLOY_REF:-refs/deploy/latest}"

deploy_mark::normalize_ref() {
  local ref="$1"

  if [[ "${ref}" == refs/* ]]; then
    echo "${ref}"
  else
    echo "refs/${ref}"
  fi
}

deploy_mark::ref_for_env() {
  local env_name="$1"
  echo "refs/deploy/${env_name}-latest"
}

deploy_mark::help() {
  echo ""
  echo -e "${BOLD}mono deploy-mark${NC} – Deploy-Stand markieren"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono deploy-mark [optionen]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --env <name>        Environment verwenden (setzt refs/deploy/<name>-latest)"
  echo "  --ref <name>        Eigenen Ref-Namen verwenden (Standard: ${DEPLOY_REF})"
  echo "  --push              Ref automatisch zum Remote pushen"
  echo "  --help, -h          Diese Hilfe anzeigen"
  echo ""
  echo -e "${BOLD}Beispiele:${NC}"
  echo "  mono deploy-mark                    # Setzt refs/deploy/latest auf HEAD"
  echo "  mono deploy-mark --env dev          # Setzt refs/deploy/dev-latest auf HEAD"
  echo "  mono deploy-mark --push             # Setzt Ref und pusht zum Remote"
  echo "  mono deploy-mark --ref deploy/prod  # Eigener Ref-Name (wird zu refs/deploy/prod)"
  echo "  MONO_DEPLOY_REF=refs/deploy/main-latest mono deploy-mark --push"
  echo ""
}

deploy_mark::run() {
  local ref="${DEPLOY_REF}"
  local env_name=""
  local push=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        env_name="${2:-}"
        if [[ -z "${env_name}" ]]; then
          mono::error "Option --env benötigt einen Wert"
          return 1
        fi
        ref="$(deploy_mark::ref_for_env "${env_name}")"
        shift 2
        ;;
      --env=*)
        env_name="${1#--env=}"
        if [[ -z "${env_name}" ]]; then
          mono::error "Option --env benötigt einen Wert"
          return 1
        fi
        ref="$(deploy_mark::ref_for_env "${env_name}")"
        shift
        ;;
      --ref|--tag)
        ref="${2:-}"
        shift 2
        ;;
      --push)
        push=true
        shift
        ;;
      --help|-h)
        deploy_mark::help
        return 0
        ;;
      *)
        mono::error "Unbekannte Option: $1"
        deploy_mark::help
        return 1
        ;;
    esac
  done

  local full_ref
  full_ref="$(deploy_mark::normalize_ref "${ref}")"
  local head_sha
  head_sha="$(git -C "${MONO_ROOT}" rev-parse --short HEAD)"

  # Alten Stand loggen falls vorhanden
  if git -C "${MONO_ROOT}" rev-parse --verify "${full_ref}" &>/dev/null; then
    local old_sha
    old_sha="$(git -C "${MONO_ROOT}" rev-parse --short "${full_ref}")"
    mono::log "Alter Stand ${BOLD}${full_ref}${NC} (${old_sha}) wird aktualisiert"
  fi

  # Ref setzen/aktualisieren
  git -C "${MONO_ROOT}" update-ref "${full_ref}" HEAD
  mono::log "Ref ${BOLD}${full_ref}${NC} gesetzt auf ${BOLD}${head_sha}${NC}"

  # Optional pushen
  if [[ "${push}" == true ]]; then
    git -C "${MONO_ROOT}" push origin "${full_ref}" --force 2>/dev/null
    mono::log "Ref zum Remote gepusht"
  fi

  echo ""
}

# ─── Start ──────────────────────────────────────────────────────────────────
deploy_mark::run "$@"
