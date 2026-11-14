// Fills about.html.
//
// Same arrangement as preload.js: a preload keeps DOM access with
// contextIsolation on, so nothing has to be handed to the page. The version
// numbers are all in process.versions, which a preload can read and a
// sandboxed page cannot; the app's own version comes from package.json, which
// only the main process has, hence the one IPC call.
const { ipcRenderer } = require('electron');

const setText = (id, text) => {
  const element = document.getElementById(id);
  if (element) element.innerText = text;
};

window.addEventListener('DOMContentLoaded', async () => {
  for (const dependency of [ 'electron', 'chrome', 'node', 'v8' ]) {
    setText(dependency + '-version', process.versions[dependency]);
  }
  setText('platform', process.platform + ' ' + process.arch);

  try {
    setText('app-version', await ipcRenderer.invoke('get-app-version'));
  } catch (error) {
    // Leave the placeholder rather than blanking the line: the rest of the
    // window is still worth reading.
    console.error('Could not read the app version: ' + error);
  }
});
