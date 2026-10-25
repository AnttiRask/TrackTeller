#!/usr/bin/env bash
# Regenerate renv.lock INSIDE the image's base (rocker/r-ver, Ubuntu 24.04), not
# on a laptop: a lock made on a different R or OS can record packages that
# don't restore in the image. Installs the app's direct packages from Posit
# Package Manager's prebuilt Linux binaries into a clean library, records them
# (plus renv at the version renv/activate.R pins) and copies the lock out.
#
# Usage: infra/regenerate_renv_lock.sh [output-path]   (default: ./renv.lock)
# Keep the package list in sync with the library() calls in app/.
set -euo pipefail

BASE_IMAGE=rocker/r-ver:4.5.2     # keep in sync with the Dockerfile
RENV_VERSION=1.0.3                # keep in sync with renv/activate.R
OUT="${1:-renv.lock}"
NAME=trackteller-lock
DIRECT='c("bslib","conflicted","dplyr","ggplot2","httr2","jsonlite","magick","plotly","purrr","shiny","stringr","tidyr","waiter")'

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" "$BASE_IMAGE" sleep infinity >/dev/null

# The same system libraries as the Dockerfile
docker exec "$NAME" bash -c 'apt-get update && apt-get install -y --no-install-recommends \
  cmake make libcurl4-openssl-dev libicu-dev libmagick++-dev gsfonts libssl-dev libuv1-dev zlib1g-dev'

docker exec "$NAME" Rscript -e "
options(
  repos = c(CRAN = 'https://p3m.dev/cran/__linux__/noble/latest'),
  HTTPUserAgent = sprintf('R/%s R (%s)', getRversion(),
    paste(getRversion(), R.version\$platform, R.version\$arch, R.version\$os))
)
lib <- '/tmp/cleanlib'; dir.create(lib)
direct <- $DIRECT
install.packages(direct, lib = lib)
install.packages('https://cran.r-project.org/src/contrib/Archive/renv/renv_${RENV_VERSION}.tar.gz',
                 repos = NULL, type = 'source', lib = lib)
library(renv, lib.loc = lib)
options(repos = c(CRAN = 'https://cloud.r-project.org'))
renv::snapshot(library = lib, packages = c(direct, 'renv'), lockfile = '/tmp/renv.lock',
               prompt = FALSE, force = TRUE)
"

docker cp "$NAME:/tmp/renv.lock" "$OUT"

# Every package a locked package requires must itself be in the lock
python3 - "$OUT" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
pk = lock["Packages"]
# Packages that ship with R itself never get a lock entry
base = {"R", "compiler", "datasets", "grDevices", "graphics", "grid", "methods", "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils"}
missing = sorted({r for p in pk.values() for r in p.get("Requirements", []) if r not in pk and r not in base})
print(f"{len(pk)} packages, R {lock['R']['Version']}, renv {pk['renv']['Version']}")
if missing:
    sys.exit("Requirements missing from the lock: " + ", ".join(missing))
print("closure complete")
PY
