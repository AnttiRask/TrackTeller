// Before login only the first tab (the welcome and the login button) works; the others
// are greyed out and can't be opened, from the keyboard or the phone menu either. The
// page starts in the signed-out state, so a signed-out visitor never sees the tabs
// enabled for a moment while it loads.
(function () {
    var OPEN_TAB = "top_artists";
    var TIP = "Log in to see this";
    var root = document.documentElement;

    root.classList.add("signed-out");

    function signedOut() {
        return root.classList.contains("signed-out");
    }

    function locked(link) {
        return signedOut() && link.getAttribute("data-value") !== OPEN_TAB;
    }

    // Mark the links, so that assistive technology and the keyboard agree with the look
    function refresh() {
        document.querySelectorAll(".navbar .nav-link[data-value]").forEach(function (link) {
            if (locked(link)) {
                link.setAttribute("aria-disabled", "true");
                link.setAttribute("tabindex", "-1");
                link.setAttribute("title", TIP);
            } else {
                link.removeAttribute("aria-disabled");
                link.removeAttribute("tabindex");
                link.removeAttribute("title");
            }
        });
    }

    // Stop the click before Bootstrap sees it (Enter on a focused link is a click too).
    // Bootstrap listens in the capture phase on document, so this has to be on window,
    // which comes before it.
    window.addEventListener("click", function (event) {
        var link = event.target.closest ? event.target.closest(".navbar .nav-link[data-value]") : null;
        if (link && locked(link)) {
            event.preventDefault();
            event.stopImmediatePropagation();
        }
    }, true);

    // The server says whether somebody is logged in
    $(document).on("shiny:value", function (event) {
        if (event.name !== "is_authenticated") return;
        root.classList.toggle("signed-out", event.value !== true);
        refresh();
    });

    $(refresh);
})();
