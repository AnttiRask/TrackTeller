#!/usr/bin/env bash
# Negative and positive permission tests for the deploy service account.
# Needs roles/iam.serviceAccountTokenCreator on it for the person running this.
# Changes nothing: it asks Google which permissions the account holds
# (testIamPermissions) and prints only the answers, never a token or a secret.
set -euo pipefail

PROJECT=trackteller-app
REGION=europe-north1
DEPLOY=trackteller-deploy@${PROJECT}.iam.gserviceaccount.com

TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$DEPLOY" </dev/null)

# ask <url> <json array of permissions>  -> prints the permissions that are GRANTED
ask() {
  curl -sS -X POST "$1" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"permissions\": $2}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['permissions'] if 'permissions' in d else (d['error'].get('message','error') if 'error' in d else []))"
}

# ask_gcs <bucket> <permission> -> prints the permissions GRANTED (Cloud Storage wants a GET)
ask_gcs() {
  curl -sS -G "https://storage.googleapis.com/storage/v1/b/$1/iam/testPermissions" \
    --data-urlencode "permissions=$2" -H "Authorization: Bearer $TOKEN" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['permissions'] if 'permissions' in d else (d['error'].get('message','error') if 'error' in d else []))"
}

report() { # report <label> <granted-as-python-list-or-error>
  echo "  $1 -> $2"
}

echo "== Should be DENIED (expect [] for each: nothing granted)"
P="https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT}:testIamPermissions"
report "read secret values / list secrets (project)" "$(ask "$P" '["secretmanager.versions.access","secretmanager.secrets.list","secretmanager.secrets.get"]')"
report "change project IAM / grant itself a role"    "$(ask "$P" '["resourcemanager.projects.setIamPolicy"]')"
report "list or create service accounts, keys"       "$(ask "$P" '["iam.serviceAccounts.list","iam.serviceAccounts.create","iam.serviceAccountKeys.create"]')"
report "create or delete other Cloud Run services"   "$(ask "$P" '["run.services.create"]')"
report "change the service's IAM (public/private)"   "$(ask "https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/services/trackteller-app:testIamPermissions" '["run.services.setIamPolicy"]')"
for S in SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET; do
  report "read value of secret $S" "$(ask "https://secretmanager.googleapis.com/v1/projects/${PROJECT}/secrets/${S}:testIamPermissions" '["secretmanager.versions.access"]')"
done
report "read the Cloud Build bucket"  "$(ask_gcs "${PROJECT}_cloudbuild" storage.objects.get)"

echo
echo "== Should be GRANTED (expect each permission listed)"
report "deploy: update the one service" "$(ask "https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/services/trackteller-app:testIamPermissions" '["run.services.update","run.services.get"]')"
report "start builds, list buckets (project)" "$(ask "$P" '["cloudbuild.builds.create","storage.buckets.list"]')"
report "upload source to the build bucket" "$(ask_gcs "run-sources-${PROJECT}-${REGION}" storage.objects.create)"
