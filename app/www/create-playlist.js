// The Create button of the playlist dialog: the moment it is clicked it says so and can't be
// clicked again. Making a playlist can take a while (for the artists list, one request per
// artist), the dialog stays on screen until the server has finished, and a second click would
// make a second playlist. (The server also handles each dialog's click only once.)
document.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("#confirm_create_playlist");
    if (!button) return;

    // After Shiny's own click handler has taken the click
    window.setTimeout(function () {
        button.disabled = true;
        button.textContent = "Creating…";
    }, 0);
});
