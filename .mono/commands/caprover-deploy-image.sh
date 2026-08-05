#!/usr/bin/env bash
# description: Deployt ein Docker-Image auf eine CapRover-App
#
# Minimaler, abhängigkeitsarmer Ersatz für:
#   caprover deploy --appToken <token> --imageName <image>
#
# Deployt ein bereits gebautes Docker-Image auf eine bestehende CapRover-App,
# indem direkt der HTTP-API-Call nachgebaut wird, den caprover-cli intern
# macht (siehe src/api/ApiManager.ts#uploadCaptainDefinitionContent und
# src/api/HttpClient.ts#createHeaders im caprover-cli-Repo).
#
# Es wird KEIN Quellcode gepackt/hochgeladen (kein git archive, kein tar) -
# es wird nur ein "captain-definition"-JSON mit dem Image-Namen an den
# Server geschickt. Der Server zieht das Image selbst und deployt es.
#
# Abhängigkeiten: nur bash + curl (kein node, kein jq, kein git nötig).
#
# Benötigte Umgebungsvariablen:
#   CAPROVER_URL        z.B. https://captain.example.com
#   CAPROVER_APP        App-Name, wie er auf dem CapRover-Server registriert ist
#   CAPROVER_APP_TOKEN  App-Token (CapRover Dashboard -> App -> Deployment ->
#                        Method 3: Deploy via CLI/Tarball, Enable App Token)
#   IMAGE_NAME           Docker-Image inkl. Tag, z.B. registry.example.com/my-app:1.2.3
#                        (kann auch als erstes Argument übergeben werden)
#
# Optional:
#   CAPROVER_WATCH=1     nach dem Trigger den Build-Status pollen (alle 2s),
#                         bis der Server fertig ist. Log-Text-Ausgabe ist
#                         Best-Effort (kein echter JSON-Parser, siehe unten).
#
# CLI-Parameter (alternativ zu Env-Variablen):
#   --caproverUrl <url>
#   --appName <name>
#   --appToken <token>
#   -i, --image <image>
#   -w, --watch            aktiviert Polling bis Build-Ende
#   -h, --help             zeigt Hilfe
#
# Beispiele:
#   mono caprover-deploy-image registry.example.com/my-app:1.2.3 \
#     --caproverUrl https://captain.example.com \
#     --appName my-app \
#     --appToken xxxxxxxx
#
#   CAPROVER_URL=https://captain.example.com \
#   CAPROVER_APP=my-app \
#   CAPROVER_APP_TOKEN=xxxxxxxx \
#   CAPROVER_WATCH=1 \
#   mono caprover-deploy-image registry.example.com/my-app:1.2.3

caprover_deploy_image::help() {
  echo ""
  echo -e "${BOLD}mono caprover-deploy-image${NC} – Docker-Image auf CapRover deployen"
  echo ""
  echo -e "${BOLD}Verwendung:${NC}"
  echo "  mono caprover-deploy-image [OPTIONS] [IMAGE_NAME]"
  echo ""
  echo -e "${BOLD}Optionen:${NC}"
  echo "  --caproverUrl <url>   CapRover-URL (z.B. https://captain.example.com)"
  echo "  --appName <name>      App-Name auf dem CapRover-Server"
  echo "  --appToken <token>    App-Token aus dem CapRover-Dashboard"
  echo "  -i, --image <image>   Docker-Image inkl. Tag"
  echo "  -w, --watch           Warte auf Build-Ergebnis (Polling alle 2s)"
  echo "  -h, --help            Diese Hilfe anzeigen"
  echo ""
  echo "Alternativ koennen die Werte per Env-Variablen gesetzt werden:"
  echo "  CAPROVER_URL, CAPROVER_APP, CAPROVER_APP_TOKEN, IMAGE_NAME, CAPROVER_WATCH"
  echo ""
  echo -e "${BOLD}Beispiel:${NC}"
  echo "  mono caprover-deploy-image registry.example.com/my-app:1.2.3 \\"
  echo "    --caproverUrl https://captain.example.com \\"
  echo "    --appName my-app --appToken xxxxxxxx --watch"
  echo ""
}

# --- kleine Helfer zum Auslesen einzelner JSON-Felder, ohne jq -------------
# Das ist bewusst KEIN generischer JSON-Parser, sondern ein gezieltes Muster
# für die paar flachen Felder, die die CapRover-API zurückgibt
# (status, description, isAppBuilding, isBuildFailed). Für diese Felder ist
# das robust; für beliebig verschachteltes JSON wäre es das nicht.

caprover_deploy_image::json_string_field() {
  # Wert eines "key": "irgendein string" Feldes
  local json="$1" key="$2"
  printf '%s' "$json" \
    | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -n1 \
    | sed -E "s/^\"$key\"[[:space:]]*:[[:space:]]*\"(.*)\"\$/\\1/"
}

caprover_deploy_image::json_raw_field() {
  # Wert eines "key": true/false/123 Feldes (kein String)
  local json="$1" key="$2"
  printf '%s' "$json" \
    | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[a-zA-Z0-9.]*" \
    | head -n1 \
    | sed -E 's/^.*:[[:space:]]*//'
}

caprover_deploy_image::run() {
  local caprover_url_arg=""
  local caprover_app_arg=""
  local caprover_app_token_arg=""
  local image_name_arg=""
  local watch_arg=""
  local positional_image=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --caproverUrl)
        [[ $# -ge 2 ]] || { mono::error "Fehlender Wert fuer --caproverUrl"; caprover_deploy_image::help; return 1; }
        caprover_url_arg="$2"
        shift 2
        ;;
      --appName)
        [[ $# -ge 2 ]] || { mono::error "Fehlender Wert fuer --appName"; caprover_deploy_image::help; return 1; }
        caprover_app_arg="$2"
        shift 2
        ;;
      --appToken)
        [[ $# -ge 2 ]] || { mono::error "Fehlender Wert fuer --appToken"; caprover_deploy_image::help; return 1; }
        caprover_app_token_arg="$2"
        shift 2
        ;;
      -i|--image)
        [[ $# -ge 2 ]] || { mono::error "Fehlender Wert fuer $1"; caprover_deploy_image::help; return 1; }
        image_name_arg="$2"
        shift 2
        ;;
      -w|--watch)
        watch_arg="1"
        shift
        ;;
      -h|--help)
        caprover_deploy_image::help
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        mono::error "Unbekannte Option: $1"
        caprover_deploy_image::help
        return 1
        ;;
      *)
        if [[ -z "$positional_image" ]]; then
          positional_image="$1"
        else
          mono::error "Unerwartetes zusaetzliches Argument: $1"
          caprover_deploy_image::help
          return 1
        fi
        shift
        ;;
    esac
  done

  local caprover_url="${caprover_url_arg:-${CAPROVER_URL:-}}"
  local caprover_app="${caprover_app_arg:-${CAPROVER_APP:-}}"
  local caprover_app_token="${caprover_app_token_arg:-${CAPROVER_APP_TOKEN:-}}"
  local image_name="${image_name_arg:-${IMAGE_NAME:-${positional_image:-}}}"
  local watch="${watch_arg:-${CAPROVER_WATCH:-0}}"

  if [[ -z "$caprover_url" ]]; then
    mono::error "CAPROVER_URL nicht gesetzt (z.B. https://captain.example.com)"
    return 1
  fi
  if [[ -z "$caprover_app" ]]; then
    mono::error "CAPROVER_APP nicht gesetzt (App-Name auf dem CapRover-Server)"
    return 1
  fi
  if [[ -z "$caprover_app_token" ]]; then
    mono::error "CAPROVER_APP_TOKEN nicht gesetzt (App-Token aus dem CapRover-Dashboard)"
    return 1
  fi
  if [[ -z "$image_name" ]]; then
    mono::error "IMAGE_NAME nicht gesetzt (Docker-Image, z.B. myregistry/app:tag)"
    return 1
  fi

  local base="${caprover_url%/}/api/v2"

  mono::log "Deploye Image ${BOLD}${image_name}${NC} auf App ${BOLD}${caprover_app}${NC} (${caprover_url})..."

  # captainDefinitionContent ist selbst ein JSON-String (wird vom Server als
  # Text gespeichert und dann geparst) - also müssen dessen eigene
  # Anführungszeichen für den äußeren JSON-Body escaped werden.
  local definition_content="{\"schemaVersion\":2,\"imageName\":\"${image_name}\"}"
  local escaped_definition
  escaped_definition=$(printf '%s' "$definition_content" | sed 's/"/\\"/g')
  local body="{\"captainDefinitionContent\":\"${escaped_definition}\",\"gitHash\":\"\"}"

  local response
  response=$(curl -sS -X POST "${base}/user/apps/appData/${caprover_app}?detached=1" \
    -H "Content-Type: application/json" \
    -H "x-namespace: captain" \
    -H "x-captain-app-token: ${caprover_app_token}" \
    -d "$body")

  local status description
  status=$(caprover_deploy_image::json_raw_field "$response" status)
  description=$(caprover_deploy_image::json_string_field "$response" description)

  # 100 = OKAY, 101 = OKAY_BUILD_STARTED (siehe ErrorFactory.ts in caprover-cli)
  if [[ "$status" != "100" && "$status" != "101" ]]; then
    mono::error "CapRover-API antwortete mit status=${status}: ${description}"
    mono::error "Rohe Antwort: ${response}"
    return 1
  fi

  mono::log "OK: ${description:-Build gestartet} (status=${status})"
  mono::log "Der Build läuft jetzt asynchron auf dem Server."

  if [[ "$watch" != "1" ]]; then
    return 0
  fi

  mono::log "Warte auf Build-Ergebnis (Polling alle 2s)..."

  while true; do
    sleep 2
    local poll_response
    poll_response=$(curl -sS -X GET "${base}/user/apps/appData/${caprover_app}" \
      -H "x-namespace: captain" \
      -H "x-captain-app-token: ${caprover_app_token}")

    local building failed
    building=$(caprover_deploy_image::json_raw_field "$poll_response" isAppBuilding)
    failed=$(caprover_deploy_image::json_raw_field "$poll_response" isBuildFailed)

    # Best-effort: rohen Log-Text lesbar machen (kein echtes JSON-Parsing).
    # Kann bei exotischen Zeichen im Build-Output ungenau werden.
    printf '%s' "$poll_response" \
      | sed -n 's/.*"lines":\[\(.*\)\],"firstLineNumber".*/\1/p' \
      | sed -E 's/","/\n/g; s/^"//; s/"$//; s/\\n/\n/g; s/\\"/"/g'

    if [[ "$failed" == "true" ]]; then
      mono::error "Build ist fehlgeschlagen."
      return 1
    fi

    if [[ "$building" != "true" ]]; then
      mono::log "Build abgeschlossen."
      break
    fi
  done
}

# ─── Start ──────────────────────────────────────────────────────────────────
caprover_deploy_image::run "$@"
