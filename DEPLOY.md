# Deploying TrackTeller-app to Google Cloud Run

## Prerequisites

1. **Google Cloud Account** - [Create one here](https://cloud.google.com/) (includes $300 free credit)
2. **gcloud CLI** - Install from [cloud.google.com/sdk](https://cloud.google.com/sdk/docs/install)

## Step 1: Install gcloud CLI

```bash
# Ubuntu/Debian
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud init
```

## Step 2: Set Up Google Cloud Project

```bash
# Create a new project (or use existing)
gcloud projects create trackteller-app --name="TrackTeller"

# Set as active project
gcloud config set project trackteller-app

# Enable required APIs
gcloud services enable cloudbuild.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable artifactregistry.googleapis.com
```

## Step 3: Build and Deploy

```bash
# Deploy directly from source (Cloud Build will build the Docker image)
gcloud run deploy trackteller-app \
  --source . \
  --platform managed \
  --region europe-north1 \
  --allow-unauthenticated \
  --set-env-vars "SPOTIFY_CLIENT_ID=your_client_id" \
  --set-env-vars "SPOTIFY_CLIENT_SECRET=your_client_secret" \
  --set-env-vars "APP_URL=https://trackteller-app-XXXXXX-lz.a.run.app" \
  --memory 1Gi \
  --timeout 300
```

**Note:** Replace `your_client_id` and `your_client_secret` with your Spotify credentials.

## Step 4: Get Your App URL

After deployment, Cloud Run will give you a URL like:
```
https://trackteller-app-abc123xyz-lz.a.run.app
```

## Step 5: Update Spotify Developer Dashboard

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard/)
2. Select your app
3. Click "Edit Settings"
4. Add your Cloud Run URL to "Redirect URIs"
5. Save

## Step 6: Redeploy with Correct APP_URL

Now that you have the URL, redeploy with the correct `APP_URL`:

```bash
gcloud run deploy trackteller-app \
  --source . \
  --platform managed \
  --region europe-north1 \
  --allow-unauthenticated \
  --set-env-vars "SPOTIFY_CLIENT_ID=your_client_id" \
  --set-env-vars "SPOTIFY_CLIENT_SECRET=your_client_secret" \
  --set-env-vars "APP_URL=https://trackteller-app-XXXXXX-lz.a.run.app" \
  --memory 1Gi \
  --timeout 300
```

## Using Secrets (Recommended for Production)

For better security, store credentials as secrets:

```bash
# Create secrets
echo -n "your_client_id" | gcloud secrets create spotify-client-id --data-file=-
echo -n "your_client_secret" | gcloud secrets create spotify-client-secret --data-file=-

# Grant Cloud Run access to secrets
gcloud secrets add-iam-policy-binding spotify-client-id \
  --member="serviceAccount:YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding spotify-client-secret \
  --member="serviceAccount:YOUR_PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Deploy with secrets
gcloud run deploy trackteller-app \
  --source . \
  --platform managed \
  --region europe-north1 \
  --allow-unauthenticated \
  --set-secrets "SPOTIFY_CLIENT_ID=spotify-client-id:latest" \
  --set-secrets "SPOTIFY_CLIENT_SECRET=spotify-client-secret:latest" \
  --set-env-vars "APP_URL=https://your-app-url.run.app" \
  --memory 1Gi \
  --timeout 300
```

## Cost Estimate

With Cloud Run's free tier:
- **Free**: 2 million requests/month
- **Free**: 360,000 GB-seconds of memory
- **Free**: 180,000 vCPU-seconds

For a personal project with occasional use, this should be **completely free**.

## Updating the App

To deploy updates:

```bash
gcloud run deploy trackteller-app --source .
```

## Monitoring

View logs:
```bash
gcloud run logs read trackteller-app --region europe-north1
```

View in console:
- [Cloud Run Console](https://console.cloud.google.com/run)
