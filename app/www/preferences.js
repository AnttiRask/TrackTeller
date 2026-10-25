// Remembers the two shared choices (time range, number to show) in this browser,
// and tells the server what was saved when the page connects. Only these two
// values are stored; nothing about the account or the listening. If the browser
// blocks storage, the app works the same, it just doesn't remember.
(function () {
    var KEY = "trackteller.prefs";
    var FIELDS = ["time_range", "shown_count"];

    function read() {
        try {
            var saved = JSON.parse(window.localStorage.getItem(KEY));
            return saved && typeof saved === "object" ? saved : {};
        } catch (e) {
            return {};
        }
    }

    function write(prefs) {
        try {
            window.localStorage.setItem(KEY, JSON.stringify(prefs));
        } catch (e) { /* storage blocked or full: carry on without it */ }
    }

    // Read now, before Shiny starts and fires change events for the default values
    var saved = read();

    // Don't save anything until the server has applied what was saved: the defaults
    // that Shiny reports at startup would overwrite it.
    var applied = false;

    $(document).on("shiny:connected", function () {
        Shiny.setInputValue("saved_prefs", saved, { priority: "event" });
    });

    $(document).on("shiny:inputchanged", function (event) {
        if (!applied || FIELDS.indexOf(event.name) === -1) return;
        var prefs = read();
        prefs[event.name] = event.value;
        write(prefs);
    });

    // Shiny insists that a message handler takes exactly one argument
    Shiny.addCustomMessageHandler("prefs_applied", function (ignored) {
        applied = true;
    });
})();
