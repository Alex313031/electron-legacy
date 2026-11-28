// Message box tests, for Tools > Dialog Tests.
//
// Every native message box Electron shows on Windows is one function,
// TaskDialogIndirect, which is comctl32 version 6 and Vista. Windows XP has no
// such thing, and there winwrap draws the dialog itself -- so each option
// dialog.showMessageBox() takes is a feature that implementation has to have,
// and these go through them one at a time: the icon for each type, the text
// with and without a detail line, buttons Windows names and buttons the app
// names, the checkbox, a caller's own icon, closing from code.
//
// On Vista and later the same items exercise the system's dialog, which is a
// useful thing to hold the XP one up against.
//
// Each test writes what came back to the log (Tools > Open Log File), and
// "Run All" shows the lot in one box at the end.
const { BrowserWindow, dialog, nativeImage } = require('electron');
const path = require('path');
const electronLog = require('electron-log');

const customIcon = path.join(__dirname, 'imgs/icon64.png');

// A stack trace's worth of text: what the uncaught-exception box has to fit.
const longText = [
  'Error: Cannot find package \'example\' imported from',
  'C:\\Program Files\\Example App\\resources\\app.asar\\node_modules\\some-module\\index.js',
  '    at packageResolve (node:internal/modules/esm/resolve:873:9)',
  '    at moduleResolve (node:internal/modules/esm/resolve:946:18)',
  '    at defaultResolve (node:internal/modules/esm/resolve:1188:11)',
  '    at ModuleLoader.defaultResolve (node:internal/modules/esm/loader:642:12)',
  '    at ModuleLoader.resolve (node:internal/modules/esm/loader:591:25)',
  '    at ModuleLoader.getModuleJob (node:internal/modules/esm/loader:347:38)',
  '',
  'And a paragraph with no line breaks of its own, to see where the dialog '
    + 'decides to wrap it and how wide it lets itself get before it does: the '
    + 'quick brown fox jumps over the lazy dog, twice, and then once more.'
].join('\n');

// name: the menu label.
// expect: what to look for, shown in the log beside the result.
// options: what showMessageBox() is given. A function when it needs something
//          made at the time, like an AbortSignal that is already counting.
// parent: false to show the box with no owner window.
const tests = [
  {
    name: 'Type: none',
    expect: 'no icon, one OK button',
    options: { type: 'none', title: 'Type: none', message: 'A message box with no icon.' }
  },
  {
    name: 'Type: info',
    expect: 'information icon',
    options: { type: 'info', title: 'Type: info', message: 'For your information.' }
  },
  {
    name: 'Type: question',
    expect: 'information icon (Windows has no question icon for these)',
    options: {
      type: 'question',
      title: 'Type: question',
      message: 'Is this a question?',
      buttons: [ 'Yes', 'No' ]
    }
  },
  {
    name: 'Type: warning',
    expect: 'warning icon',
    options: { type: 'warning', title: 'Type: warning', message: 'Consider yourself warned.' }
  },
  {
    name: 'Type: error',
    expect: 'error icon',
    options: { type: 'error', title: 'Type: error', message: 'Something went wrong.' }
  },
  {
    name: 'Message and Detail',
    expect: 'the message as a heading, the detail as body text under it',
    options: {
      type: 'info',
      title: 'Message and Detail',
      message: 'This line is the message',
      detail: 'And this is the detail. With a detail present the message becomes the '
        + 'dialog\'s main instruction, which is drawn as a heading.'
    }
  },
  {
    name: 'No Title',
    expect: 'the app name in the caption',
    options: { type: 'info', message: 'No title was given, so the caption is the app\'s name.' }
  },
  {
    name: 'Common Buttons',
    expect: 'OK, Yes, No, Retry, Cancel, Close in the system\'s order and language; '
      + 'response is the index in the order given here',
    options: {
      type: 'question',
      title: 'Common Buttons',
      message: 'Every button Windows has a name for.',
      detail: 'Given as Close, Cancel, Retry, No, Yes, OK. Windows lays them out its own way.',
      buttons: [ 'Close', 'Cancel', 'Retry', 'No', 'Yes', 'OK' ],
      cancelId: 1
    }
  },
  {
    name: 'Custom Buttons (command links)',
    expect: 'three large stacked buttons, Cancel in the row below; the second is the default',
    options: {
      type: 'question',
      title: 'Custom Buttons',
      message: 'Buttons with the app\'s own labels',
      detail: 'Without noLink, labels Windows does not know become command links.',
      buttons: [ 'Save and Restart', 'Restart Without Saving', 'Do Something Else', 'Cancel' ],
      defaultId: 1,
      cancelId: 3
    }
  },
  {
    name: 'Custom Buttons (noLink)',
    expect: 'the same four as ordinary buttons in one row; the third is the default',
    options: {
      type: 'question',
      title: 'Custom Buttons, noLink',
      message: 'The same buttons, with noLink',
      buttons: [ 'Save and Restart', 'Restart Without Saving', 'Do Something Else', 'Cancel' ],
      noLink: true,
      defaultId: 2,
      cancelId: 3
    }
  },
  {
    name: 'Access Keys',
    expect: 'underlined S, D and C (after pressing Alt); Alt+S, Alt+D, Alt+C press them',
    options: {
      type: 'question',
      title: 'Access Keys',
      message: 'Buttons with access keys',
      buttons: [ '&Save', '&Don\'t Save', '&Cancel' ],
      noLink: true,
      normalizeAccessKeys: true,
      cancelId: 2
    }
  },
  {
    name: 'Checkbox, clear',
    expect: 'an unticked checkbox; checkboxChecked follows what you leave it as',
    options: {
      type: 'info',
      title: 'Checkbox',
      message: 'A checkbox that starts clear',
      checkboxLabel: 'Do not show this again',
      checkboxChecked: false,
      buttons: [ 'OK', 'Cancel' ]
    }
  },
  {
    name: 'Checkbox, ticked',
    expect: 'a ticked checkbox',
    options: {
      type: 'info',
      title: 'Checkbox',
      message: 'A checkbox that starts ticked',
      checkboxLabel: 'Do not show this again',
      checkboxChecked: true,
      buttons: [ 'OK', 'Cancel' ]
    }
  },
  {
    name: 'Custom Icon',
    expect: 'the app\'s own icon in place of a system one',
    options: {
      title: 'Custom Icon',
      message: 'An icon the app supplied',
      detail: 'From ' + customIcon,
      icon: nativeImage.createFromPath(customIcon)
    }
  },
  {
    name: 'Long Text',
    expect: 'wrapped text and a dialog that still fits the screen',
    options: {
      type: 'error',
      title: 'Long Text',
      message: 'A JavaScript error occurred in the main process',
      detail: longText
    }
  },
  {
    name: 'No Parent Window',
    expect: 'a box centred on the screen, and the main window still usable behind it',
    parent: false,
    options: {
      type: 'info',
      title: 'No Parent Window',
      message: 'This box has no owner window.'
    }
  },
  {
    name: 'Escape and Close Box',
    expect: 'pressing Esc or the close box returns cancelId, here 2',
    options: {
      type: 'question',
      title: 'Escape and Close Box',
      message: 'Press Esc, or close this from its title bar',
      detail: 'Neither is one of the three buttons. The response should be cancelId, 2.',
      buttons: [ 'One', 'Two', 'Three' ],
      noLink: true,
      cancelId: 2
    }
  },
  {
    name: 'Closes Itself (AbortSignal)',
    expect: 'the box goes away by itself after three seconds; response is cancelId, 1',
    options: () => ({
      type: 'info',
      title: 'Closes Itself',
      message: 'Leave this alone',
      detail: 'It is closed from code in three seconds, through an AbortSignal.',
      buttons: [ 'OK', 'Cancel' ],
      cancelId: 1,
      signal: AbortSignal.timeout(3000)
    })
  }
];

function parentFor(test) {
  if (test.parent === false) return null;
  return BrowserWindow.getFocusedWindow() || BrowserWindow.getAllWindows()[0] || null;
}

function describe(test, result) {
  return test.name + ': response ' + result.response
    + ', checkboxChecked ' + result.checkboxChecked;
}

async function runTest(test) {
  const options = typeof test.options === 'function' ? test.options() : test.options;
  const parent = parentFor(test);
  electronLog.info('Dialog test "' + test.name + '" -- expect ' + test.expect);
  try {
    const result = parent
      ? await dialog.showMessageBox(parent, options)
      : await dialog.showMessageBox(options);
    const line = describe(test, result);
    electronLog.info('Dialog test ' + line);
    return line;
  } catch (error) {
    electronLog.error('Dialog test "' + test.name + '" threw: ' + error);
    return test.name + ': threw ' + error;
  }
}

// The blocking form, which reaches the same function by another route: no
// promise, the main process waits in the call.
function runSync() {
  const parent = parentFor({});
  const options = {
    type: 'question',
    title: 'showMessageBoxSync',
    message: 'The synchronous form',
    detail: 'The main process is blocked until this is answered.',
    buttons: [ 'Yes', 'No', 'Cancel' ],
    cancelId: 2
  };
  const response = parent
    ? dialog.showMessageBoxSync(parent, options)
    : dialog.showMessageBoxSync(options);
  const line = 'showMessageBoxSync: response ' + response;
  electronLog.info('Dialog test ' + line);
  return line;
}

// dialog.showErrorBox(), which is also what an uncaught exception in the main
// process ends in. No buttons are asked for, so there is one OK.
function runErrorBox() {
  dialog.showErrorBox('showErrorBox', 'The title above is the heading and this is the content.\n\n'
    + longText);
  electronLog.info('Dialog test showErrorBox: returned');
  return 'showErrorBox: returned';
}

async function runAll() {
  const lines = [];
  for (const test of tests) {
    lines.push(await runTest(test));
  }
  lines.push(runSync());
  lines.push(runErrorBox());
  const parent = parentFor({});
  const summary = {
    type: 'info',
    title: 'Dialog Tests',
    message: lines.length + ' dialogs shown',
    detail: lines.join('\n')
  };
  if (parent) {
    await dialog.showMessageBox(parent, summary);
  } else {
    await dialog.showMessageBox(summary);
  }
}

// The submenu, for menu.js.
function dialogTestMenu() {
  return [
    {
      label: 'Run All',
      click() {
        runAll();
      }
    },
    { type: 'separator' },
    ...tests.map((test) => ({
      label: test.name,
      click() {
        runTest(test);
      }
    })),
    { type: 'separator' },
    {
      label: 'showMessageBoxSync',
      click() {
        runSync();
      }
    },
    {
      label: 'showErrorBox',
      click() {
        runErrorBox();
      }
    }
  ];
}

module.exports = { dialogTestMenu };
