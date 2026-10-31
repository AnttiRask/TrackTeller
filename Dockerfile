# R 4.5.2 matches renv.lock. r-ver is much smaller than rocker/shiny, and we
# only need R: app/run.R starts the app with shiny::runApp()
FROM rocker/r-ver:4.6.0

# System libraries for the R packages in renv.lock on this Ubuntu release (24.04,
# "noble"). The list comes from Posit Package Manager's sysreqs API:
#   https://p3m.dev/__api__/repos/cran/sysreqs?distribution=ubuntu&release=24.04&all=true
# libmagick++-dev (+ gsfonts) is for magick, which draws the share cards;
# fonts-liberation is the font those cards use ("Liberation Sans"), and fonts-noto-cjk
# the one for names in Chinese, Japanese or Korean ("Noto Sans CJK JP", about 90 MB;
# ImageMagick can't fall back from one font to another within a text). cmake and
# make are only used if a pinned package has to be compiled. Retries tolerate
# transient apt mirror failures.
RUN for i in 1 2 3; do \
        apt-get update && apt-get install -y --no-install-recommends \
            cmake \
            make \
            fonts-liberation \
            fonts-noto-cjk \
            gsfonts \
            libcurl4-openssl-dev \
            libicu-dev \
            libmagick++-dev \
            libssl-dev \
            libuv1-dev \
            zlib1g-dev \
        && break || { echo "apt attempt $i failed, retrying in $((i*15))s"; sleep $((i*15)); }; \
    done \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# renv infrastructure first, so the (slow) package layer is cached until the
# lockfile changes
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json

# No renv cache: by default renv installs into a cache under the build user's
# home (/root) and only symlinks packages into the project library, which the
# non-root runtime user can't read. Real copies in /app/renv/library work for
# everyone. No sandbox at runtime either (it would create directories on every start).
ENV RENV_CONFIG_CACHE_ENABLED=FALSE
ENV RENV_CONFIG_SANDBOX_ENABLED=FALSE

# Restore from Posit Package Manager's prebuilt Linux binaries for this distro
RUN CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")" \
    && R -q -e "options(renv.config.repos.override = c(CRAN = 'https://p3m.dev/cran/__linux__/${CODENAME}/latest')); renv::restore(prompt = FALSE)"

# Application files (.dockerignore lets only app/ through)
COPY app app

# Don't run as root. The app writes its sass cache under app/app_cache.
RUN useradd --system --create-home --shell /usr/sbin/nologin trackteller \
    && chown -R trackteller:trackteller /app
USER trackteller

# Cloud Run sets PORT; the Spotify credentials are injected at runtime
# (Secret Manager), never baked into the image
ENV PORT=8080
ENV SHINY_ENV=production
EXPOSE 8080

CMD ["Rscript", "app/run.R"]
