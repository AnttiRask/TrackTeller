#!/usr/bin/env bash
# Keyless deploy identity for TrackTeller (Workload Identity Federation).
# Mirrors the TuneTeller setup: GitHub Actions on AnttiRask/TrackTeller, branch
# main only, impersonates a narrow service account. No key is ever created.
#
# Run it by hand, once, as the project owner. Every step prints what it does and
# stops on the first error (set -e). Re-running skips things that already exist.
set -euo pipefail

PROJECT=trackteller-app
REGION=europe-north1
SERVICE=trackteller-app
NUMBER=957085714294
REPO=AnttiRask/TrackTeller

DEPLOY_SA=trackteller-deploy@${PROJECT}.iam.gserviceaccount.com
RUNTIME_SA=trackteller-runtime@${PROJECT}.iam.gserviceaccount.com
COMPUTE_SA=${NUMBER}-compute@developer.gserviceaccount.com
POOL=trackteller
PROVIDER=github-oidc
BUCKET=run-sources-${PROJECT}-${REGION}
ROLE_ID=trackTellerBucketLister

step() { echo; echo "== $*"; }
g() { gcloud "$@" --project "$PROJECT" </dev/null; }

# A service account that was created seconds ago is not always visible to other
# Google APIs yet (Cloud Run's IAM answers "does not exist"). Retry a few times,
# showing every error; give up loudly.
retry() {
  local n
  for n in 1 2 3 4 5 6 7 8; do
    if "$@"; then return 0; fi
    echo "attempt $n failed; waiting 15 s for the new account to propagate..." >&2
    sleep 15
  done
  echo "giving up after 8 attempts" >&2
  return 1
}

step "1. Enable the Security Token Service API (needed for the token exchange)"
g services enable sts.googleapis.com

step "2. Workload identity pool '$POOL'"
if g iam workload-identity-pools describe "$POOL" --location global >/dev/null 2>&1; then
  echo "exists"
else
  g iam workload-identity-pools create "$POOL" --location global --display-name "TrackTeller GitHub"
fi

step "3. OIDC provider '$PROVIDER' (this repo, refs/heads/main only)"
if g iam workload-identity-pools providers describe "$PROVIDER" --location global --workload-identity-pool "$POOL" >/dev/null 2>&1; then
  echo "exists"
else
  g iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --location global --workload-identity-pool "$POOL" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
    --attribute-condition "assertion.repository=='${REPO}' && assertion.ref=='refs/heads/main'"
fi

step "4. Deploy service account"
if g iam service-accounts describe "$DEPLOY_SA" >/dev/null 2>&1; then
  echo "exists"
else
  g iam service-accounts create trackteller-deploy --display-name "TrackTeller deploy (GitHub Actions)"
fi

step "5. Only this repo (via the pool) may impersonate it"
g iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${REPO}"

step "6. Narrow permissions, resource-level where possible"
echo "- deploy to the one service"
retry g run services add-iam-policy-binding "$SERVICE" --region "$REGION" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/run.developer
echo "- act as the runtime account and as the build account (the default compute account)"
g iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/iam.serviceAccountUser
g iam service-accounts add-iam-policy-binding "$COMPUTE_SA" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/iam.serviceAccountUser
echo "- push the image to the source-deploy repository"
g artifacts repositories add-iam-policy-binding cloud-run-source-deploy --location "$REGION" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/artifactregistry.writer
echo "- upload source to the build bucket (that bucket only)"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --project "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/storage.objectAdmin </dev/null
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" --project "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/storage.legacyBucketReader </dev/null
echo "- start builds, and list buckets (gcloud needs it to find the staging bucket)"
g projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role roles/cloudbuild.builds.editor --condition=None
if g iam roles describe "$ROLE_ID" >/dev/null 2>&1; then
  echo "custom role exists"
else
  g iam roles create "$ROLE_ID" --title "TrackTeller bucket lister" --permissions storage.buckets.list
fi
g projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:${DEPLOY_SA}" --role "projects/${PROJECT}/roles/${ROLE_ID}" --condition=None

step "Done. Values for the workflow:"
echo "workload_identity_provider: projects/${NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"
echo "service_account:            ${DEPLOY_SA}"
