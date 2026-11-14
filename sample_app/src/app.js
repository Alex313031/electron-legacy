const { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, systemPreferences, Tray } = require('electron');
const electronLog = require('electron-log');
// electron-context-menu v4+ is ESM-only, so require() yields its module
// namespace and the function lives on .default
const contextMenu = require('electron-context-menu').default;
// electron-store v9+ is ESM-only, so require() yields its module namespace
// and the class lives on .default
const Store = require('electron-store').default;
const fs = require('fs');
const os = require('os');
const path = require('path');
const url = require('url');
const mainMenu = require('./menu.js'); // For making native menu
const { defaultUserAgent } = require('./useragent.js'); // Chrome-shaped UA for pop-outs

// Whether we are in development mode
const isDev = process.env.NODE_ENV === 'development';

// Create storage config.json
const store = new Store();

// Restrict main.log size to 100Kb
electronLog.initialize();
electronLog.transports.file.maxSize = 1024 * 100;

// Get app details from package.json
const appName = app.getName();
const appVersion = app.getVersion();

// Globally export what OS we are on
const isLinux = process.platform === 'linux';
const isWin = process.platform === 'win32';
const isMac = process.platform === 'darwin';

const argsCmd = process.argv; // Global cmdline object.
let mainWindow; // Main Window object
let tray; // OS tray object
let mainActivated; // Global activate? object

async function createWindow() {
  mainWindow = new BrowserWindow({
    title: 'Electron Legacy Test',
    resizable: true,
    maximizable: true,
    width: 1024,
    height: 768,
    useContentSize: true,
    icon: isWin ? path.join(__dirname, 'imgs/icon.ico') : path.join(__dirname, 'imgs/icon64.png'),
    darkTheme: store.get('options.useLightMode') ? false : true,
    autoHideMenuBar: false,
    frame: true,
    webPreferences: {
      nodeIntegration: false,
      nodeIntegrationInWorker: false,
      contextIsolation: true,
      sandbox: true,
      experimentalFeatures: true,
      devTools: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });

  Menu.setApplicationMenu(mainMenu(app, mainWindow, store));

  // Reset the Window's size and location
  // (options.windowDetails may also be `true` or `{}` before a position was saved)
  const hasPosition = (details) => details && Array.isArray(details.position) && details.position.length === 2;
  const windowDetails = store.get('options.windowDetails');
  const relaunchWindowDetails = store.get('relaunch.windowDetails');
  if (hasPosition(relaunchWindowDetails)) {
    mainWindow.setPosition(
      relaunchWindowDetails.position[0],
      relaunchWindowDetails.position[1]
    );
  } else if (hasPosition(windowDetails)) {
    mainWindow.setPosition(
      windowDetails.position[0],
      windowDetails.position[1]
    );
  }
  store.delete('relaunch.windowDetails');

  applyTheme();

  const mainURL = url.format({
    protocol: 'file',
    slashes: true,
    pathname: path.join(__dirname, 'index.html')
  })
  mainWindow.loadURL(mainURL);
  mainWindow.on('page-title-updated', function(e) {
    e.preventDefault();
  });

  // Emitted when the window is closing
  mainWindow.on('close', () => {
    // If enabled store the window details so they can be restored upon restart
    if (store.get('options.windowDetails')) {
      if (mainWindow) {
        store.set('options.windowDetails', {
          position: mainWindow.getPosition()
        });
        electronLog.info('Saved windowDetails.');
      } else {
        electronLog.error('Error: mainWindow was not defined while trying to save windowDetails.');
      }
    }
    electronLog.info('Closed mainWindow');
    // Explicit, rather than left to process exit: on Windows an icon whose
    // owner goes away without calling NIM_DELETE can be left behind in the
    // notification area until something hovers over it, which is a visible
    // difference between Windows versions and worth not provoking by accident.
    if (tray) {
      tray.destroy();
      tray = null;
      electronLog.info('Destroyed tray icon');
    }
    mainWindow.destroy();
  });

  // Emitted when the window is closed. Registered as a named listener so that
  // the 'restart' and 'relaunch' handlers can actually remove it again.
  mainWindow.on('closed', mainWindowClosed);
}

contextMenu({
  showSelectAll: false,
  showCopyImage: true,
  showCopyImageAddress: true,
  showSaveImageAs: true,
  showCopyVideoAddress: true,
  showSaveVideoAs: true,
  showCopyLink: true,
  showSaveLinkAs: true,
  showInspectElement: true,
  showLookUpSelection: true,
  showSearchWithGoogle: true,
  prepend: (defaultActions, parameters) => [
  {
    label: 'Open Link in New Window',
    // Only show it when right-clicking a link
    visible: parameters.linkURL.trim().length > 0,
    click: () => {
      const toURL = parameters.linkURL;
      const linkWin = new BrowserWindow({
        title: 'New Window',
        width: 1024,
        height: 700,
        useContentSize: true,
        darkTheme: store.get('options.useLightMode') ? false : true,
        webPreferences: {
          nodeIntegration: false,
          nodeIntegrationInWorker: false,
          experimentalFeatures: true,
          devTools: true
        }
      });
      linkWin.webContents.userAgent = defaultUserAgent();
      linkWin.loadURL(toURL);
      electronLog.info('Opened Link in New Window');
    }
  },
  {
    label: 'Open Image in New Window',
    // Only show it when right-clicking an image
    visible: parameters.mediaType === 'image',
    click: () => {
      const imgURL = parameters.srcURL;
      const imgTitle = imgURL.substring(imgURL.lastIndexOf('/') + 1);
      const imgWin = new BrowserWindow({
        title: imgTitle,
        useContentSize: true,
        darkTheme: store.get('options.useLightMode') ? false : true,
        webPreferences: {
          nodeIntegration: false,
          nodeIntegrationInWorker: false,
          experimentalFeatures: true,
          devTools: true
        }
      });
      imgWin.webContents.userAgent = defaultUserAgent();
      imgWin.loadURL(imgURL);
      electronLog.info('Opened Image in New Window');
    }
  },
  {
    label: 'Open Video in New Window',
    // Only show it when right-clicking a video
    visible: parameters.mediaType === 'video',
    click: () => {
      const vidURL = parameters.srcURL;
      const vidTitle = vidURL.substring(vidURL.lastIndexOf('/') + 1);
      const vidWin = new BrowserWindow({
        title: vidTitle,
        useContentSize: true,
        darkTheme: store.get('options.useLightMode') ? false : true,
        webPreferences: {
          nodeIntegration: false,
          nodeIntegrationInWorker: false,
          experimentalFeatures: true,
          devTools: true
        }
      });
      vidWin.webContents.userAgent = defaultUserAgent();
      vidWin.loadURL(vidURL);
      electronLog.info('Popped out Video');
    }
  }]
});

ipcMain.handle('finished-preload', () => {
  electronLog.info('[ electron:preload ] IPC Listeners Created');
});

// about.html reads the app version from package.json via the main process
ipcMain.handle('get-app-version', () => appVersion);

// Everything index.html needs that a sandboxed renderer cannot see for itself.
// Each probe is caught individually: the point of the page is to report which
// pieces work, so one missing piece must not blank out the rest.
ipcMain.handle('get-test-facts', () => {
  return {
    appVersion: appVersion,
    osRelease: os.type() + ' ' + os.release() + ' (' + os.arch() + ')',
    nodeAbi: process.versions.modules,
    commandLine: argsCmd,
    aeroGlass: readAeroGlass(),
    nativeModule: loadNativeModule(),
    widevineCdmPath: app.commandLine.getSwitchValue('widevine-cdm-path'),
    widevineCdmPresent: readCdmPresence()
  };
});

// Whether --widevine-cdm-path points at anything. patches/other/14 accepts
// either a directory holding the CDM and its manifest, or the CDM binary
// itself, so this only reports what is there and leaves judging it to the
// patch -- a path that exists is still no guarantee the CDM loads.
function readCdmPresence() {
  const cdmPath = app.commandLine.getSwitchValue('widevine-cdm-path');
  if (!cdmPath) {
    return 'N/A';
  }
  try {
    const stat = fs.statSync(cdmPath);
    return stat.isDirectory() ? 'Yes - directory' : 'Yes - file';
  } catch (error) {
    return 'No (' + (error.code || error.message) + ')';
  }
}

// systemPreferences.isAeroGlassEnabled(), restored by patches/other/10.
// Returns null off Windows, or the error text if the API is not there -- which
// is itself the result worth seeing, since a stock Electron 36+ has removed it.
function readAeroGlass() {
  if (!isWin) {
    return null;
  }
  try {
    if (typeof systemPreferences.isAeroGlassEnabled !== 'function') {
      return 'isAeroGlassEnabled() is not a function! (is patches/other/10 applied?)';
    }
    return systemPreferences.isAeroGlassEnabled();
  } catch (error) {
    return String(error);
  }
}

// Exercises the native-module path. bufferutil is a single small C++ addon, so
// a failure here is about the toolchain or the ABI rather than the module.
function loadNativeModule() {
  try {
    const bufferutil = require('bufferutil');
    // Call it, rather than only loading it: a stub that resolves but does not
    // actually run would otherwise look like a pass.
    const masked = Buffer.alloc(4);
    bufferutil.mask(Buffer.from([ 1, 2, 3, 4 ]), Buffer.from([ 0, 0, 0, 0 ]), masked, 0, 4);
    return { loaded: true, detail: 'mask() ran, ABI ' + process.versions.modules };
  } catch (error) {
    return { loaded: false, detail: String(error.message || error) };
  }
}

// Run a script inside the main window's page. Failures (e.g. the window is
// already being destroyed during close/quit, or the page threw) are logged
// instead of becoming unhandled promise rejections in the main process.
function runInMainWindow(script) {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return Promise.resolve();
  }
  return mainWindow.webContents.executeJavaScript(script).catch((error) => {
    electronLog.warn('executeJavaScript failed: ' + error);
  });
}

// Run when window is closed. This cleans up the mainWindow object to save resources.
function mainWindowClosed() {
  mainWindow = null;
  mainActivated = null;
  if (isDev) {
    electronLog.warn('mainWindowClosed()');
  }
}

// Log when we reload
app.on('reload', () => {
  mainWindow.reload();
  electronLog.info('mainWindow reloaded');
});

app.on('will-quit', () => {
  electronLog.warn(appName + ' is quitting now');
});

// Quit when all windows are closed.
app.on('window-all-closed', () => {
  //if (process.platform !== 'darwin') {
    app.quit();
  //}
});

// On macOS it's common to re-create a window in the app when the
// dock icon is clicked and there are no other windows open.
app.on('activate', () => {
  if (mainActivated === null) {
    electronLog.info('App Re-Activated [ Loading app.js ]');
    createWindow();
  }
});

// Full restart, quitting Electron.
app.on('restart', () => {
  electronLog.warn('Restarting App...');

  store.set('relaunch.windowDetails', {
    position: mainWindow.getPosition()
  });

  // Close Window
  mainWindow.removeListener('closed', mainWindowClosed);

  // Tell app we are going to relaunch
  app.relaunch();
  // Kill Electron to initiate the relaunch
  app.quit();
});

// Dialog box asking if user really wants to restart app
app.on('restart-confirm', () => {
  dialog.showMessageBox(mainWindow, {
    'type': 'question',
    'title': 'Restart Confirmation',
    'message': 'Are you sure you want to restart the test app?',
    'buttons': [
      'Yes',
      'No'
    ]
  })
  // Dialog returns a promise so let's handle it correctly
  .then((result) => {
    // Bail if the user pressed "No" or escaped (ESC) from the dialog box
    if (result.response !== 0) {
      return;
    }
    // Continue emitting the restart
    if (result.response === 0) {
      app.emit('restart');
    }
  });
});

// Pushes options.useLightMode at Chromium.
//
// nativeTheme.themeSource is a live override rather than a startup choice: set
// it and Chromium hands the new preference to every renderer, so the
// prefers-color-scheme queries in main.css re-evaluate where they stand and
// nothing has to reload. That matters here beyond taste, because a reload would
// throw away a page whose whole content was measured once at load.
//
// What a restart still changes is the GTK window variant, which comes from
// BrowserWindow's darkTheme option and is fixed when the window is created.
// That is the Linux title bar only, never the page.
function applyTheme() {
  nativeTheme.themeSource = store.get('options.useLightMode') ? 'light' : 'dark';
}

app.on('theme-changed', () => {
  applyTheme();
  // A Menu is a snapshot of the labels it was built with, and this one reads
  // "Use Dark Mode" or "Use Light Mode" depending on which way the setting
  // currently points -- so it has to be rebuilt for the label to follow. Safe
  // whatever state the window is in: menu.js never touches the mainWindow it
  // is handed, it asks for the focused window when it needs one.
  Menu.setApplicationMenu(mainMenu(app, mainWindow, store));
  electronLog.info('Theme switched to ' + nativeTheme.themeSource);
});

app.on('toggle-menubar', () => {
  if (store.get('options.autoHideMenuBar')) {
    mainWindow.autoHideMenuBar = true;
    mainWindow.menuBarVisible = false;
  } else {
    mainWindow.autoHideMenuBar = false;
    mainWindow.menuBarVisible = true;
  }
  electronLog.info('Note: Changed menu visibility setting');
});

// Builds the notification area icon.
//
// This is here to be tested on old Windows rather than to be useful. Electron's
// Tray is Shell_NotifyIcon underneath, and the notification area is one of the
// places where XP and Vista differ most from Win10: which mouse events arrive,
// whether a balloon appears at all or is translated into a toast, how long a
// tooltip may be, and what happens to the icon when Explorer restarts. The tray
// menu exposes each of those as something to click, and every handler logs, so
// a run on an unfamiliar machine leaves a record of what the OS actually did.
function handleTray() {
  if (store.get('options.disableTray')) {
    electronLog.info('Tray disabled by options.disableTray');
    return;
  }
  if (tray) {
    return;
  }

  // Windows wants the .ico: it carries the 16x16 the notification area asks
  // for, and letting Shell scale a 64px PNG down looks it.
  const trayIcon = isWin
    ? path.join(__dirname, 'imgs/icon.ico')
    : path.join(__dirname, 'imgs/icon64.png');

  try {
    tray = new Tray(trayIcon);
  } catch (error) {
    // Not fatal: the window is the app, the tray is a convenience. A throw
    // here is itself a result worth recording on an old OS.
    electronLog.error('Could not create the tray icon: ' + error);
    tray = null;
    return;
  }

  tray.setToolTip(appName + ' ' + appVersion);
  tray.setContextMenu(buildTrayMenu());

  // Windows sends click and double-click separately, and right-click opens the
  // context menu on its own. Logging all three shows which ones a given
  // Windows actually delivers.
  tray.on('click', () => {
    electronLog.info('Tray: click');
    toggleFromTray();
  });
  tray.on('double-click', () => {
    electronLog.info('Tray: double-click');
    showFromTray();
  });
  tray.on('right-click', () => {
    electronLog.info('Tray: right-click');
  });
  tray.on('middle-click', () => {
    electronLog.info('Tray: middle-click');
  });

  // The answer to "did the balloon actually appear". Windows reports these
  // from the shell, so silence after Test Balloon means the request went
  // nowhere rather than that the notification was merely missed.
  tray.on('balloon-show', () => {
    electronLog.info('Tray: balloon shown');
  });
  tray.on('balloon-click', () => {
    electronLog.info('Tray: balloon clicked');
  });
  tray.on('balloon-closed', () => {
    electronLog.info('Tray: balloon closed (timeout or dismissed)');
  });

  electronLog.info('Created tray icon from ' + trayIcon);
}

function buildTrayMenu() {
  return Menu.buildFromTemplate([
    {
      label: 'Show ' + appName,
      click() {
        showFromTray();
      }
    },
    {
      label: 'Hide to Tray',
      click() {
        minimizeToTray();
      }
    },
    { type: 'separator' },
    {
      // Windows only. On XP and Vista this is a real Shell_NotifyIcon balloon;
      // from Win8 on, Windows turns it into a toast instead, so what appears
      // here says which path the OS took.
      label: 'Test Balloon',
      visible: isWin,
      click() {
        if (!tray) return;
        try {
          tray.displayBalloon({
            title: appName,
            content: 'Balloon from the notification area. On XP and Vista this '
              + 'is a Shell_NotifyIcon balloon; later Windows shows a toast.',
            iconType: 'info'
          });
          electronLog.info('Tray: requested a balloon');
        } catch (error) {
          electronLog.error('displayBalloon() failed: ' + error);
        }
      }
    },
    {
      // NOTIFYICONDATA's tooltip is 64 characters in the original struct and
      // 128 in the version XP introduced. If a long tooltip comes back
      // truncated at 64, the shorter struct is in play.
      label: 'Test Long Tooltip',
      click() {
        if (!tray) return;
        const long = ('Tooltip length probe: this string is deliberately past '
          + '64 characters so truncation is visible. ').slice(0, 127);
        tray.setToolTip(long);
        electronLog.info('Tray: set a ' + long.length + ' character tooltip');
      }
    },
    {
      label: 'Reset Tooltip',
      click() {
        if (!tray) return;
        tray.setToolTip(appName + ' ' + appVersion);
        electronLog.info('Tray: reset the tooltip');
      }
    },
    { type: 'separator' },
    {
      label: 'Destroy Tray',
      click() {
        if (!tray) return;
        tray.destroy();
        tray = null;
        electronLog.warn('Tray: destroyed. Re-create it from Tools.');
      }
    },
    { type: 'separator' },
    {
      label: 'Quit',
      click() {
        app.quit();
      }
    }
  ]);
}

// A single click on Windows is the usual "get the window back" gesture, and
// the same click should put it away again.
function toggleFromTray() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    electronLog.info('Tray: no window to toggle, creating one');
    createWindow();
    return;
  }
  if (mainWindow.isVisible() && mainWindow.isFocused()) {
    minimizeToTray();
  } else {
    showFromTray();
  }
}

function showFromTray() {
  // The tray can be clicked before the window exists, and after it is gone.
  if (!mainWindow || mainWindow.isDestroyed()) {
    electronLog.info('Tray: no window to show, creating one');
    createWindow();
    return;
  }
  if (mainWindow.isVisible()) {
    mainWindow.focus();
    if (!mainWindow.isFocused()) {
      electronLog.info('Focused mainWindow');
    }
  } else {
    mainWindow.show();
    electronLog.info('Restored from Tray');
  }
}

function minimizeToTray() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return;
  }
  // Without a tray there is nothing to restore from, so minimize instead of
  // hiding the window somewhere the user cannot reach it.
  if (!tray) {
    mainWindow.minimize();
    electronLog.info('Minimized (no tray to hide into)');
    return;
  }
  if (mainWindow.isVisible()) {
    mainWindow.hide();
    electronLog.info('Minimized to Tray');
  } else {
    electronLog.info('mainWindow already minimized to Tray');
  }
}

app.on('minimize-to-tray', () => {
  minimizeToTray();
});

app.on('show-from-tray', () => {
  showFromTray();
});

app.commandLine.appendSwitch('enable-local-file-accesses');
app.commandLine.appendSwitch('enable-quic');
app.commandLine.appendSwitch('enable-ui-devtools');
// Enable remote debugging only if we are in development mode
if (isDev) {
  const portNumber = '9222'
  app.commandLine.appendSwitch('remote-debugging-port', portNumber);
  electronLog.warn('Remote debugging open on port ' + [ portNumber ]);
}

// Lets the Tools menu put the icon back after "Destroy Tray", and is what the
// tray toggle in Settings would use if it stopped requiring a restart.
app.on('create-tray', () => {
  handleTray();
});

// Fire it up
app.whenReady().then(async() => {
    // Window first: the tray's click handler and its menu both act on
    // mainWindow, and a click can arrive the moment the icon appears.
    createWindow();
    handleTray();
});
