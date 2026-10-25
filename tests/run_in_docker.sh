#!/usr/bin/env bash
# Run the testthat suite inside the production image, so the tests see exactly
# the R and package versions that run in production. testthat itself is not in
# renv.lock (the app doesn't need it); it is installed beside the project
# library from Posit's Linux binaries on every run.
#
# Usage: tests/run_in_docker.sh [image]    (default: trackteller-ci)
# Build the image first: docker build -t trackteller-ci .
set -euo pipefail

IMAGE="${1:-trackteller-ci}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker run --rm -v "$HERE:/app/tests:ro" -w /app "$IMAGE" Rscript -e '
options(
  repos = c(CRAN = "https://p3m.dev/cran/__linux__/noble/latest"),
  HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(),
    paste(getRversion(), R.version$platform, R.version$arch, R.version$os))
)
dir.create("/tmp/testlib"); .libPaths(c("/tmp/testlib", .libPaths()))
install.packages("testthat", lib = "/tmp/testlib", quiet = TRUE)
testthat::test_dir("tests/testthat", reporter = "summary", stop_on_failure = TRUE)
'
