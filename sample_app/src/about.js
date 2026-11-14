// The About window.
//
// A page rather than dialog.showMessageBox(), for the same reason the rest of
// this app is a page: it is another thing to look at on an old Windows. A
// second BrowserWindow with its own sandboxed preload exercises a code path
// the main window cannot -- a non-first window, its own renderer process, its
// own preload -- and it picks up main.css, so whatever the theme is doing it
// does here too.
//
// Deliberately not a child window. `parent` would be conventional for an about
// box, but this app hides its main window into the notification area, and an
// owned window goes with its owner: the About box would vanish on "Hide to
// Tray" with no way to get it back.
const { BrowserWindow, shell } = require('electron');
const path = require('path');
const electronLog = require('electron-log');

let aboutWindow; // The single About window, if one is open

function openAboutWindow(app, store) {
  // One at a time. Clicking About twice should bring back what is already
  // there rather than stack a second copy on top of it.
  if (aboutWindow && !aboutWindow.isDestroyed()) {
    if (aboutWindow.isMinimized()) aboutWindow.restore();
    aboutWindow.show();
    aboutWindow.focus();
    electronLog.info('About window already open');
    return aboutWindow;
  }

  const isWin = process.platform === 'win32';
  aboutWindow = new BrowserWindow({
    title: 'About ' + app.getName(),
    width: 460,
    height: 460,
    useContentSize: true,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    autoHideMenuBar: true,
    icon: isWin ? path.join(__dirname, 'imgs/icon.ico') : path.join(__dirname, 'imgs/icon64.png'),
    darkTheme: store.get('options.useLightMode') ? false : true,
    webPreferences: {
      nodeIntegration: false,
      nodeIntegrationInWorker: false,
      contextIsolation: true,
      sandbox: true,
      devTools: true,
      preload: path.join(__dirname, 'about_preload.js')
    }
  });

  // Keep the title the BrowserWindow was given rather than about.html's, so
  // the app name stays whatever package.json says it is.
  aboutWindow.on('page-title-updated', (event) => {
    event.preventDefault();
  });

  // Links go to the real browser. Both halves are needed: target="_blank"
  // arrives as a window-open request, and anything else would navigate the
  // About page itself to somewhere it has no business being.
  aboutWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    electronLog.info('Opened externally: ' + url);
    return { action: 'deny' };
  });
  aboutWindow.webContents.on('will-navigate', (event, url) => {
    if (url === aboutWindow.webContents.getURL()) return;
    event.preventDefault();
    shell.openExternal(url);
    electronLog.info('Opened externally: ' + url);
  });

  aboutWindow.on('closed', () => {
    aboutWindow = null;
  });

  aboutWindow.loadFile(path.join(__dirname, 'about.html'));
  electronLog.info('Opened About window');
  return aboutWindow;
}

module.exports = { openAboutWindow };
