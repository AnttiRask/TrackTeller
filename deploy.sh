#!/usr/bin/env bash
# Manual deploy of TrackTeller to Google Cloud Run: the fallback for when GitHub Actions
# can't do it (the normal deploy is .github/workflows/deploy_shiny_app.yml; keep the
# service flags below in sync with it).
#
# Credentials: nothing is read from a .env file and nothing is asked for.
#   - If SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET are both set in the environment,
#     they are checked and stored in Secret Manager when they differ from what is there.
#   - Otherwise the values already in Secret Manager are used (after the same check).
#
# Usage:   ./deploy.sh              deploy the current checkout
#          ./deploy.sh --dry-run    check everything and print what would happen; changes nothing
set -euo pipefail

PROJECT_ID="trackteller-app"
REGION="europe-north1"
SERVICE_NAME="trackteller-app"
# Fixed on purpose: an APP_URL left in the shell (the local one, say) must never be deployed
PRODUCTION_URL="https://trackteller.youcanbeapirate.com"
SECRETS=(SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET)

DRY_RUN=false
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== TrackTeller deployment$($DRY_RUN && echo ' (dry run: nothing is changed)') ===${NC}"

if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}" >&2
    echo "Install it from: https://cloud.google.com/sdk/docs/install" >&2
    exit 1
fi

if [ -z "$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null)" ]; then
    echo -e "${RED}Not logged in to Google Cloud. Run: gcloud auth login${NC}" >&2
    exit 1
fi

# A Spotify client id or secret is 32 lowercase hex characters. Anything else (a quote,
# a \r, a space) is a stored-wrong-value outage waiting to happen. The value is never
# printed, only what is wrong with it.
check_credential() {
    local name="$1" value="$2"
    if [ -z "$value" ]; then
        echo -e "${RED}Error: ${name} is empty${NC}" >&2
        return 1
    fi
    if ! [[ "$value" =~ ^[a-f0-9]{32}$ ]]; then
        echo -e "${RED}Error: ${name} is not 32 lowercase hex characters (it has ${#value} characters)${NC}" >&2
        return 1
    fi
}

stored_value() {
    gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID" 2>/dev/null || true
}

echo -e "${YELLOW}Checking the Spotify credentials...${NC}"
if [ -n "${SPOTIFY_CLIENT_ID:-}" ] && [ -n "${SPOTIFY_CLIENT_SECRET:-}" ]; then
    echo "  using the values from the environment"
    for name in "${SECRETS[@]}"; do
        value="${!name}"
        check_credential "$name" "$value"
        stored="$(stored_value "$name")"
        if [ "$value" = "$stored" ]; then
            echo "  $name: unchanged"
        elif $DRY_RUN; then
            echo "  $name: would be stored as a new version"
        elif [ -z "$stored" ] && ! gcloud secrets describe "$name" --project="$PROJECT_ID" &> /dev/null; then
            printf '%s' "$value" | gcloud secrets create "$name" --data-file=- --replication-policy=automatic --project="$PROJECT_ID" > /dev/null
            echo "  $name: created"
        else
            printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- --project="$PROJECT_ID" > /dev/null
            echo "  $name: updated"
        fi
    done
else
    echo "  using the values already in Secret Manager"
    for name in "${SECRETS[@]}"; do
        check_credential "$name" "$(stored_value "$name")" || {
            echo "  Set both SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET in the environment to store new values." >&2
            exit 1
        }
        echo "  $name: ok"
    done
fi

# Which commit this revision is. A checkout with uncommitted changes says so.
SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    SHA="${SHA}-dirty"
    echo -e "${YELLOW}Note: there are uncommitted changes; the revision is labelled ${SHA}${NC}"
fi

DEPLOY_ARGS=(
    run deploy "$SERVICE_NAME"
    --project "$PROJECT_ID"
    --source .
    --platform managed
    --region "$REGION"
    --allow-unauthenticated
    --service-account "trackteller-runtime@${PROJECT_ID}.iam.gserviceaccount.com"
    --set-secrets "SPOTIFY_CLIENT_ID=SPOTIFY_CLIENT_ID:latest"
    --set-secrets "SPOTIFY_CLIENT_SECRET=SPOTIFY_CLIENT_SECRET:latest"
    --set-env-vars "APP_URL=$PRODUCTION_URL"
    --memory 1Gi
    --timeout 3600
    --session-affinity
    --max-instances 3
    --update-labels "git-sha=${SHA}"
)

if $DRY_RUN; then
    echo -e "${GREEN}Would run:${NC} gcloud ${DEPLOY_ARGS[*]}"
    exit 0
fi

echo -e "${GREEN}Deploying ${SHA} with APP_URL ${PRODUCTION_URL}${NC}"
gcloud "${DEPLOY_ARGS[@]}"

echo ""
echo -e "${GREEN}=== Deployment complete ===${NC}"
echo "Live at: ${PRODUCTION_URL}"
echo "The Spotify dashboard must list ${PRODUCTION_URL} as a redirect URI (it does already)."
