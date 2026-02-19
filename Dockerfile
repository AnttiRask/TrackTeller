# Use rocker/shiny as base image
FROM rocker/shiny:4.3.1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libmagick++-dev \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Create app directory
WORKDIR /srv/shiny-server/app

# Copy renv files separately for better layer caching
COPY renv.lock renv.lock
COPY .Rprofile .Rprofile
COPY renv/activate.R renv/activate.R

# Install renv
RUN R -e "install.packages('renv', repos = 'https://cloud.r-project.org/')"

# Restore packages from renv.lock
RUN R -e "renv::restore()"

# Install magick (not in renv.lock; cached separately from app code)
RUN R -e "renv::install('magick')"

# Copy application files
COPY . .

# Set permissions
RUN chown -R shiny:shiny /srv/shiny-server/app

# Expose port
EXPOSE 8080

# Set environment variables
ENV PORT=8080
ENV SHINY_ENV=production

# Run the application
CMD ["R", "-e", "source('run.R')"]
