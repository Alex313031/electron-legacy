// The user agent to give pop-out windows.
//
// Electron's own default carries both the app token and "Electron/<version>",
// e.g.
//   ... ElectronLegacyTest/0.0.1 Chrome/152.0.0.0 Electron/44.11.1 Safari/537.36
// which a fair number of sites either refuse outright or serve a degraded page
// to. Removing those two tokens leaves exactly what plain Chrome of the same
// milestone sends, which is what a window showing someone else's page wants.
const { app } = require('electron');

// Escapes a string for use inside a RegExp. The app name is read from
// package.json, so it is not necessarily regex-safe.
function escapeForRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function defaultUserAgent() {
  const appToken = new RegExp(' ' + escapeForRegExp(app.getName()) + '\\/[^ ]+');
  return app.userAgentFallback
    .replace(/ Electron\/[^ ]+/, '')
    .replace(appToken, '');
}

module.exports = { defaultUserAgent };
