# Deploying TrackTeller

TrackTeller runs on **Google Cloud Run** (project `trackteller-app`, region `europe-north1`, service `trackteller-app`) at https://trackteller.youcanbeapirate.com.

## How a normal deploy works

You don't run anything. A push to `main` that touches `app/**` or the build files (Dockerfile, `renv.lock`, `.dockerignore`; not docs, tests or plans) starts the **Deploy to Cloud Run** workflow (`.github/workflows/deploy_shiny_app.yml`):

1. **Tests**: the same job as `tests.yml`: the image is built, the testthat suite runs inside it, and the app is started once to see that it boots. A failure stops the deploy.
2. **Deploy**: logs in to Google Cloud without a key (Workload Identity Federation, as the service account `trackteller-deploy`, for this repository's `main` branch only) and runs `gcloud run deploy --source .`.
3. **Smoke test**: checks that the service carries the `git-sha` label of the commit that was pushed, that `GET /health` answers 200 (the instance says its credentials and redirect address are in order; no Spotify call is made) and that `GET /` answers 200 (up to five tries each, ten seconds apart).

It can also be started by hand: Actions tab → *Deploy to Cloud Run* → *Run workflow*, or `gh workflow run deploy_shiny_app.yml --ref main`. A deploy takes about nine minutes.

What the service runs with (the workflow and `deploy.sh` use the same flags; keep them in sync):

| Setting | Value | Why |
| ------- | ----- | --- |
| Runtime account | `trackteller-runtime` | Can read the two Spotify secrets and nothing else |
| Secrets | `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET` from Secret Manager | Never in the repository or the image |
| `APP_URL` | `https://trackteller.youcanbeapirate.com` | The OAuth redirect address |
| Memory | 1 Gi | The share cards use ImageMagick |
| Timeout | 3600 s, session affinity | A Shiny session is one long websocket |
| Max instances | 3 | Cost limit |
| Label | `git-sha=<first 12 characters of the commit>` | Tells which commit a revision is |

## Checking a deploy

```bash
# Which revision serves, and which commit is it?
gcloud run services describe trackteller-app --region europe-north1 --project trackteller-app \
  --format='value(status.latestReadyRevisionName,status.traffic[0].percent,spec.template.metadata.labels.git-sha)'

# Errors in the last 20 minutes
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=trackteller-app AND severity>=ERROR' \
  --project trackteller-app --freshness 20m --limit 20
```

```bash
curl -i https://trackteller.youcanbeapirate.com/health   # 200 ok, or 503 unhealthy: <what is wrong>
```

Then use the live app: log in, open each tab, download a card, create a playlist.

## Rolling back

Send the traffic to the previous revision (the old image is still in the registry for two weeks, see below):

```bash
gcloud run services update-traffic trackteller-app --region europe-north1 --project trackteller-app \
  --to-revisions <revision-name>=100
```

Then fix `main`; the next deploy takes the traffic back.

## Manual deploy (fallback)

If GitHub Actions is unavailable, from a checkout of `main`, logged in with `gcloud`:

```bash
./deploy.sh --dry-run   # checks the credentials and prints the deploy command; changes nothing
./deploy.sh
```

The script reads no `.env` file and asks nothing. It uses the Spotify credentials already in Secret Manager (checked: 32 lowercase hex characters each) and deploys with the same flags as the workflow, labelling the revision with the commit (`-dirty` when there are uncommitted changes). The production URL is fixed in the script, so an `APP_URL` left in your shell can't end up in production.

To store *new* credentials, put both in the environment for that one run (without leaving them in your shell history):

```bash
read -rp "Client id: " SPOTIFY_CLIENT_ID; read -rsp "Client secret: " SPOTIFY_CLIENT_SECRET; echo
export SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET
./deploy.sh
```

A value that isn't 32 lowercase hex characters is refused before anything is stored (hidden quotes or `\r` have caused an outage before); the message never prints the value. Check the revision afterwards (see "Checking a deploy").

## First-time setup (or rebuilding the project)

1. **Spotify**: in the [Developer Dashboard](https://developer.spotify.com/dashboard/) create an app (Web API) and add the redirect URIs `https://trackteller.youcanbeapirate.com` and, for local work, `http://127.0.0.1:8080`. The app is in Development Mode: only users you add there can log in.
2. **Google Cloud**: a project with Cloud Run, Cloud Build, Artifact Registry and Secret Manager enabled; the two secrets `SPOTIFY_CLIENT_ID` and `SPOTIFY_CLIENT_SECRET`.
3. **Accounts and keyless deploy**: `infra/setup_keyless_deploy.sh` (run by hand, once, as the project owner; it prints every step and can be re-run) creates the runtime account `trackteller-runtime`, the deploy account `trackteller-deploy`, the Workload Identity pool `trackteller` and the narrow permissions. `infra/test_deploy_identity.sh` then checks what the deploy account can and cannot do (it changes nothing).
4. **Domain**: a Cloud Run domain mapping for `trackteller.youcanbeapirate.com` (a CNAME to `ghs.googlehosted.com`; the certificate is issued by Google).
5. **Registry cleanup**: `infra/artifact-registry-cleanup.json` keeps the 5 newest versions of each image and deletes the rest after 14 days:

   ```bash
   gcloud artifacts repositories set-cleanup-policies cloud-run-source-deploy \
     --location=europe-north1 --project=trackteller-app \
     --policy=infra/artifact-registry-cleanup.json --no-dry-run
   ```

   (Without `--no-dry-run` it only reports what it would delete.)
6. **Uptime check and alert**: `ALERT_EMAIL=you@example.com infra/setup_uptime_alert.sh` (the address is not kept in the repository). It creates an email channel, an uptime check on `GET /health` every five minutes (passes on 200 with the body `ok`) and an alert policy that emails when at least two locations see it fail at the same time, and when it recovers. Safe to re-run; things are matched by name. Uptime checks and email alerts are in Google's free tier at this volume. The check looks at the configuration, not at Spotify: a Spotify outage does not alert.
7. **GitHub**: the repository's `main` is protected, secret scanning and push protection are on, and Dependabot watches the Actions and the Docker base image.

## Changing the R packages

Don't snapshot on a laptop: the lock is for R 4.5.2 and a different R or OS records packages that don't restore in the image. Run `infra/regenerate_renv_lock.sh`, which builds the lock inside the image's base, and keep its package list in step with the `library()` calls in `app/`.

## Cost

Cloud Run's free tier covers a personal project with occasional use: 2 million requests, 360,000 GiB-seconds and 180,000 vCPU-seconds a month. Without a minimum instance the first visit after a quiet period waits a few seconds for a cold start. Artifact Registry storage is the one thing that grows, which is what the cleanup policy is for.
