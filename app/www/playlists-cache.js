// A copy of the user's playlist list, kept in this browser so that the My Playlists tab can
// show it at once on the next visit while the real list loads in the background.
//
// The server asks for it (playlist_cache_load), hands over a fresh one when the real list is
// complete (playlist_cache_save), and has it removed on logout or when the session ends
// (playlist_cache_clear). One entry per Spotify account. If the browser blocks storage or is
// full, nothing is kept and everything still works, just without the shortcut.
(function () {
    // Shiny insists that a message handler takes exactly one argument

    Shiny.addCustomMessageHandler("playlist_cache_load", function (msg) {
        var found = { items: [] };
        try {
            var saved = JSON.parse(window.localStorage.getItem(msg.key));
            if (saved && Array.isArray(saved.items)) found = saved;
        } catch (e) { /* unreadable or blocked: treat as nothing saved */ }
        Shiny.setInputValue(msg.input_id, found, { priority: "event" });
    });

    Shiny.addCustomMessageHandler("playlist_cache_save", function (msg) {
        try {
            window.localStorage.setItem(msg.key, JSON.stringify({ saved_at: msg.saved_at, items: msg.items }));
        } catch (e) {
            // full or blocked: drop what is there rather than keep an old copy
            try { window.localStorage.removeItem(msg.key); } catch (ignored) { }
        }
    });

    Shiny.addCustomMessageHandler("playlist_cache_clear", function (msg) {
        try {
            var doomed = [];
            for (var i = 0; i < window.localStorage.length; i++) {
                var key = window.localStorage.key(i);
                if (key && key.indexOf(msg.prefix) === 0) doomed.push(key);
            }
            doomed.forEach(function (key) { window.localStorage.removeItem(key); });
        } catch (e) { /* blocked: nothing to clear */ }
    });
})();
