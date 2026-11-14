const { BrowserWindow, Menu, screen, shell } = require('electron');
const path = require('path');
const electronLog = require('electron-log');
const { openAboutWindow } = require('./about.js'); // About window
const { openMainProcessDevTools } = require('./inspector.js'); // Main process debugger
const { defaultUserAgent } = require('./useragent.js'); // Chrome-shaped UA for pop-outs

module.exports = (app, mainWindow, store) => {
  // Get app info
  const appName = app.getName();
  const userHome = app.getPath('home');
  const userDataDir = app.getPath('userData');
  const userLogFile = path.join(userDataDir, 'logs/main.log');
  const userMacLogFile = path.join(userHome, 'Library/Logs', appName, 'main.log');
  const userConfigJson = path.join(userDataDir, 'config.json');

  // Globally export what OS we are on
  const isLinux = process.platform === 'linux';
  const isWin = process.platform === 'win32';
  const isMac = process.platform === 'darwin';

  // Get display bounds for centering secondary windows
  let currentDisplay = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
  let screenSize = currentDisplay.workArea;
  let secondaryWindowX = Math.floor(screenSize.x + ((screenSize.width / 2)));

  async function createPopOutWindow() {
    const popoutWindow = new BrowserWindow({
      width: 1024,
      height: 768,
      title: undefined,
      useContentSize: true,
      webPreferences: {
        nodeIntegration: false,
        nodeIntegrationInWorker: false,
        contextIsolation: true,
        sandbox: true,
        experimentalFeatures: true,
        devTools: true
      }
    });
    popoutWindow.webContents.userAgent = defaultUserAgent();
    popoutWindow.loadURL('https://www.google.com/');
    popoutWindow.setBounds({ x: secondaryWindowX });
    electronLog.info('Opened Popout Window');
  }

  return Menu.buildFromTemplate([
  {
    role: 'appMenu',
    label: 'File',
    submenu: [
      {
        label: 'About ' + appName,
        acceleratorWorksWhenHidden: false,
        visible: isMac ? true : false,
        role: 'about'
      },
      {
        label: 'Go Back',
        accelerator: 'Alt+Left',
        click(item, focusedWindow) {
          if (!focusedWindow) return;
          // webContents.goBack() is deprecated since Electron 32
          focusedWindow.webContents.navigationHistory.goBack();
          const currentURL = focusedWindow.webContents.getURL();
          electronLog.info('Navigated backward to ' + [ currentURL ]);
        }
      },
      {
        label: 'Go Forward',
        accelerator: 'Alt+Right',
        click(item, focusedWindow) {
          if (!focusedWindow) return;
          // webContents.goForward() is deprecated since Electron 32
          focusedWindow.webContents.navigationHistory.goForward();
          const currentURL = focusedWindow.webContents.getURL();
          electronLog.info('Navigated forward to ' + [ currentURL ]);
        }
      },
      {
        label: 'Minimize to Tray',
        visible: store.get('options.disableTray') ? false : true,
        accelerator: 'CmdorCtrl+M',
        acceleratorWorksWhenHidden: false,
        click() {
          app.emit('minimize-to-tray');
        }
      },
      {
        label: 'Minimize Window',
        visible: store.get('options.disableTray') ? true : false,
        accelerator: 'CmdorCtrl+M',
        acceleratorWorksWhenHidden: false,
        click(item, focusedWindow) {
          if (focusedWindow) focusedWindow.minimize();
          electronLog.info('Minimized a Window');
        }
      },
      {
        label: 'Close Window',
        accelerator: 'CmdorCtrl+W',
        click(item, focusedWindow) {
          if (focusedWindow) focusedWindow.close();
          electronLog.info('Closed a Window');
        }
      },
      { type: 'separator' },
      {
        label: 'Relaunch',
        click() {
          app.emit('restart-confirm');
        }
      },
      {
        label: 'Quit ' + appName,
        accelerator: 'CmdOrCtrl+Q',
        role: 'quit'
      }
    ]
  },
  {
    role: 'editMenu',
    label: 'Edit',
    submenu: [
      { role: 'undo' },
      { role: 'redo' },
      { type: 'separator' },
      { role: 'cut' },
      { role: 'copy' },
      { role: 'paste' },
      { role: 'pasteAndMatchStyle' },
      { role: 'delete' },
      { type: 'separator' },
      { role: 'selectAll' }
    ]
  },
  {
    role: 'viewMenu',
    label: 'View',
    submenu: [
      { role: 'reload' },
      { role: 'forceReload' },
      {
        label: 'Toggle Developer Tools',
        accelerator: isMac ? 'Alt+Command+I' : 'Ctrl+Shift+I',
        click(item, focusedWindow) {
          if (!focusedWindow) return;
          const currentURL = focusedWindow.webContents.getURL();
          electronLog.info('Toggling Developer Tools on ' + currentURL);
          focusedWindow.webContents.toggleDevTools();
        }
      },
      { type: 'separator' },
      { role: 'resetZoom' },
      { role: 'zoomIn' },
      { role: 'zoomOut' },
      { type: 'separator' },
      { role: 'togglefullscreen' }
    ]
  },
  {
    label: 'Settings',
    submenu: [
      {
        label: store.get('options.useLightMode') ? 'Use Dark Mode' : 'Use Light Mode',
        type: 'checkbox',
        accelerator: 'CmdorCtrl+Shift+D',
        click() {
          if (store.get('options.useLightMode')) {
            store.set('options.useLightMode', false);
          } else {
            store.set('options.useLightMode', true);
          }
          // Applied on the spot rather than at the next start: app.js pushes
          // it to nativeTheme, which every open page follows without
          // reloading, and rebuilds this menu so the label flips with it.
          app.emit('theme-changed');
        },
        checked: false
      },
      {
        label: 'Remember Window Position',
        type: 'checkbox',
        click() {
          if (store.get('options.windowDetails')) {
            store.delete('options.windowDetails');
          } else {
            store.set('options.windowDetails', {});
          }
        },
        checked: !!store.get('options.windowDetails')
      },
      {
        label: store.get('options.disableTray') ? 'Enable Tray' : 'Disable Tray',
        type: 'checkbox',
        click() {
          if (store.get('options.disableTray')) {
            store.set('options.disableTray', false);
          } else {
            store.set('options.disableTray', true);
          }
          app.emit('restart-confirm');
        },
        checked: false
      },
      {
        label: 'Edit Config File',
        click() {
          electronLog.info('Editing Config File');
          electronLog.info('\n Note that JSON must be a recognized file type \n for the OS to open the config.json file.\n');
          if (isLinux) {
            electronLog.info('\n On Linux, a default text editor for handling JSON files must also be present and configured correctly.\n');
          }
          // openInEditor() returns a Promise since electron-store v9
          Promise.resolve(store.openInEditor()).catch((error) => {
            electronLog.error('Could not open config.json in an editor: ' + error);
          });
        }
      }
    ]
  },
  {
    label: 'Tools',
    submenu: [
      {
        label: 'Reload F5',
        accelerator: 'F5',
        visible: false,
        acceleratorWorksWhenHidden: true,
        click(item, focusedWindow) {
          if (focusedWindow) focusedWindow.webContents.reload();
        }
      },
      {
        label: 'Open Log File',
        click() {
          if (isMac) {
            electronLog.info('Opening ' + [ userMacLogFile ]);
            const logWindow = new BrowserWindow({ width: 600, height: 768, useContentSize: true, title: userMacLogFile });
            logWindow.loadFile(userMacLogFile);
            logWindow.setBounds({ x: secondaryWindowX });
          } else {
            electronLog.info('Opening ' + [ userLogFile ]);
            const logWindow = new BrowserWindow({ width: 600, height: 768, useContentSize: true, title: userLogFile });
            logWindow.loadFile(userLogFile);
            logWindow.setBounds({ x: secondaryWindowX });
          }
        }
      },
      {
        label: 'Open config.json',
        click() {
          electronLog.info('Opening ' + [ userConfigJson ]);
          const confWindow = new BrowserWindow({ width: 600, height: 700, useContentSize: true, title: userConfigJson });
          confWindow.loadFile(userConfigJson);
          confWindow.setBounds({ x: secondaryWindowX });
        }
      },
      {
        label: 'Open User Data Dir',
        click() {
          electronLog.info('Opening ' + [ userDataDir ]);
          shell.openPath(userDataDir);
        }
      },
      {
        label: 'Create Popout Window',
        click() {
          createPopOutWindow();
        }
      },
      {
        // Puts the notification area icon back after the tray menu's
        // "Destroy Tray", so the create/destroy path can be exercised
        // repeatedly without restarting.
        label: 'Create Tray Icon',
        visible: store.get('options.disableTray') ? false : true,
        click() {
          app.emit('create-tray');
          electronLog.info('Requested a tray icon');
        }
      },
      { type: 'separator' },
      {
        label: 'Inspect Main Process',
        click() {
          electronLog.info('Opening Electron DevTools on the main process.');
          openMainProcessDevTools();
        }
      },
      {
        label: 'Open DevTools',
        accelerator: 'F12',
        click(item, focusedWindow) {
          if (!focusedWindow) return;
          const currentURL = focusedWindow.webContents.getURL();
          electronLog.info('Opening Developer Tools on ' + currentURL);
          focusedWindow.webContents.openDevTools();
        }
      },
      {
        // Hidden keyboard path for the main process debugger, since
        // "Inspect Main Process" deliberately leaves F12 to the page
        label: 'Inspect Main Process Extra',
        accelerator: isMac ? 'Cmd+Shift+F12' : 'Ctrl+Shift+F12',
        visible: false,
        acceleratorWorksWhenHidden: true,
        click() {
          electronLog.info('Opening Electron DevTools on the main process.');
          openMainProcessDevTools();
        }
      },
      {
        label: store.get('options.devToolsOnStart') ? 'Disable DevTools on Start' : 'Enable DevTools on Start',
        type: 'checkbox',
        click() {
          if (store.get('options.devToolsOnStart')) {
            store.set('options.devToolsOnStart', false);
          } else {
            store.set('options.devToolsOnStart', true);
          }
          app.emit('restart-confirm');
        },
        checked: false
      },
      {
        label: 'Open chrome://gpu',
        accelerator: 'CmdorCtrl+Alt+G',
        click() {
          const gpuWindow = new BrowserWindow({ width: 900, height: 700, useContentSize: true, title: 'GPU Internals' });
          gpuWindow.loadURL('chrome://gpu');
          gpuWindow.setBounds({ x: secondaryWindowX });
          electronLog.info('Opened chrome://gpu');
        }
      },
      {
        label: 'Open chrome://process-internals',
        accelerator: 'CmdorCtrl+Alt+P',
        click() {
          const procsWindow = new BrowserWindow({ width: 900, height: 700, useContentSize: true, title: 'Process Model Internals' });
          procsWindow.loadURL('chrome://process-internals');
          procsWindow.setBounds({ x: secondaryWindowX });
          electronLog.info('Opened chrome://process-internals');
        }
      },
      {
        label: 'Open chrome://media-internals',
        accelerator: 'CmdorCtrl+Alt+M',
        click() {
          const mediaWindow = new BrowserWindow({ width: 900, height: 700, useContentSize: true, title: 'Media Internals' });
          mediaWindow.loadURL('chrome://media-internals');
          mediaWindow.setBounds({ x: secondaryWindowX });
          electronLog.info('Opened chrome://media-internals');
        }
      }
    ]
  },
  {
    role: 'help',
    label: 'About',
    submenu: [
      {
        label: 'Created by Alex313031',
        click() {
          const createdWindow = new BrowserWindow({ width: 1024, height: 700, useContentSize: true });
          createdWindow.loadURL('https://github.com/Alex313031/electron-legacy#readme');
          createdWindow.setBounds({ x: secondaryWindowX });
        }
      },
      { type: 'separator' },
      {
        label: 'About App',
        accelerator: 'Ctrl+Alt+A',
        click() {
          openAboutWindow(app, store);
        }
      }
    ]
  }
  ]);
};
