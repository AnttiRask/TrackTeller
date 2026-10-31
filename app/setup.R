# Everything the app needs before the first page: packages, which package wins when two
# have the same function, and all of the app's own code. Loaded once, when the app starts
# (not once per visitor), and by the tests.

library(shiny)
library(bslib)
library(conflicted)
library(dplyr)
library(ggplot2)
library(magick)
library(plotly)
library(purrr)
library(stringr)
library(tidyr)
library(waiter)

conflict_prefer("filter", "dplyr")
conflict_prefer("validate", "shiny")

# The code is in scripts/ (the parts that don't need a session) and server/ (the parts of
# the server). Both are relative to the app folder.
for (file in c(
    "global", "config", "strings", "variables",
    "spotify_oauth", "spotify_api",
    "display", "charts", "dialogs", "list_cards", "stats_card", "security",
    "playlists", "playlists_module"
)) {
    source(file.path("scripts", paste0(file, ".R")))
}

for (file in c("auth", "shared", "artists", "tracks", "recent", "genres",
               "downloads", "create_playlist")) {
    source(file.path("server", paste0(file, ".R")))
}
