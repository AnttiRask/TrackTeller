// Handle redirect messages from Shiny server
Shiny.addCustomMessageHandler('redirect', function(url) {
    window.location.href = url;
});
