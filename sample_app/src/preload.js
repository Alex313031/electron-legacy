// Fills in index.html. A preload script keeps DOM access even with
// contextIsolation enabled, so no page script or @electron/remote is needed.
//
// This runs in a sandboxed renderer, where require() only resolves electron
// itself plus a few built-ins -- no fs, and no native modules. Anything that
// needs the main process (the app version, isAeroGlassEnabled, whether the
// native module loaded) is fetched over IPC instead.
const { ipcRenderer } = require('electron');

let osType;
if (process.platform === 'linux') {
  osType = 'Linux';
} else if (process.platform === 'win32') {
  osType = 'Win';
} else if (process.platform === 'darwin') {
  osType = 'MacOS';
} else {
  osType = 'BSD';
}

const replaceText = (selector, text) => {
  const element = document.getElementById(selector);
  if (element) element.innerText = text;
};

// Where a generated row belongs.
//
// `table.insertRow()` with no index does not append to the table body. It
// appends to the parent of the table's *last* row, so once index.html has a
// `<thead>`, the last row is the header row and every generated row lands
// inside the header -- which leaves `<tbody>` empty and makes the header's
// bold rule apply to all of them. Before the `<thead>` existed, the bare `<tr>`
// was parser-wrapped into an implicit `<tbody>` and this happened to work.
//
// So ask for the body directly. `createTBody()` covers a table written without
// one, which keeps this safe to call on any `.facts` table.
const tableBody = (table) => table.tBodies[0] || table.createTBody();

// Marks a cell good/bad as well as filling it, so the page can be read at a
// glance instead of compared against what the values are supposed to be.
//
// The class name is lower case whatever the displayed text says. CSS class
// selectors are case-sensitive in standards mode, so `yes` is the name
// main.css styles and `Yes` is a class nothing matches.
const replaceVerdict = (selector, text, good) => {
  const element = document.getElementById(selector);
  if (!element) return;
  element.innerText = text;
  element.classList.add(good ? 'yes' : 'no');
};

// --- Codecs ----------------------------------------------------------------

// MIME types worth asking about. The proprietary ones are the point of this
// fork; the royalty-free ones are here as a control, because a build where
// everything says "no" is a broken probe rather than a codec problem.
const kCodecs = [
  { label: 'H.264 (AVC)', mime: 'video/mp4; codecs="avc1.640028"' },
  { label: 'HEVC (H.265)', mime: 'video/mp4; codecs="hvc1.1.6.L93.B0"' },
  { label: 'HEVC (hev1)', mime: 'video/mp4; codecs="hev1.1.6.L93.B0"' },
  { label: 'AC-3', mime: 'audio/mp4; codecs="ac-3"' },
  { label: 'E-AC-3', mime: 'audio/mp4; codecs="ec-3"' },
  { label: 'MPEG-2 video', mime: 'video/mpeg' },
  { label: 'AAC', mime: 'audio/mp4; codecs="mp4a.40.2"' },
  { label: 'MP3', mime: 'audio/mpeg' },
  { label: 'VP9', mime: 'video/webm; codecs="vp9"' },
  { label: 'AV1', mime: 'video/mp4; codecs="av01.0.04M.08"' },
  { label: 'Opus', mime: 'audio/webm; codecs="opus"' },
  { label: 'FLAC', mime: 'audio/flac' }
];

function fillCodecTable() {
  const table = document.getElementById('codec-table');
  if (!table) return;
  const probe = document.createElement('video');
  const haveMse = typeof window.MediaSource !== 'undefined' &&
                  typeof window.MediaSource.isTypeSupported === 'function';

  for (const codec of kCodecs) {
    let verdict;
    // canPlayType returns '' (no), 'maybe' or 'probably'.
    const canPlay = probe.canPlayType(codec.mime);
    if (canPlay == 'maybe') {
      verdict = 'Maybe';
    } else if (canPlay == 'probably') {
      verdict = 'Probably';
    } else {
      verdict = 'No';
    }
    const mse = haveMse
      ? (window.MediaSource.isTypeSupported(codec.mime) ? 'Yes' : 'No')
      : 'N/A';

    const row = tableBody(table).insertRow();
    const name = document.createElement('th');
    name.innerText = codec.label;
    name.title = codec.mime;
    row.appendChild(name);

    const playCell = row.insertCell();
    playCell.innerText = verdict;
    playCell.classList.add(verdict === 'No' ? 'no' : 'yes');

    const mseCell = row.insertCell();
    mseCell.innerText = mse;
    if (mse !== 'N/A') mseCell.classList.add(mse === 'Yes' ? 'yes' : 'no');
  }
}

// --- Widevine / EME --------------------------------------------------------

// Key systems worth asking for. clearkey is the control: it needs no CDM at
// all, so if it fails too then EME itself is missing and nothing below the
// first row means anything.
const kKeySystems = [
  { label: 'clearkey (control)', system: 'org.w3.clearkey', robustness: '' },
  { label: 'widevine, unspecified', system: 'com.widevine.alpha', robustness: '' },
  { label: 'widevine, SW_SECURE_CRYPTO', system: 'com.widevine.alpha', robustness: 'SW_SECURE_CRYPTO' },
  { label: 'widevine, SW_SECURE_DECODE', system: 'com.widevine.alpha', robustness: 'SW_SECURE_DECODE' },
  { label: 'widevine, HW_SECURE_ALL', system: 'com.widevine.alpha', robustness: 'HW_SECURE_ALL' }
];

async function probeKeySystem(entry) {
  if (typeof navigator.requestMediaKeySystemAccess !== 'function') {
    return { text: 'EME unavailable', good: false };
  }
  const capability = { contentType: 'video/mp4; codecs="avc1.640028"' };
  if (entry.robustness) {
    capability.robustness = entry.robustness;
  }
  try {
    const access = await navigator.requestMediaKeySystemAccess(entry.system, [ {
      initDataTypes: [ 'cenc' ],
      videoCapabilities: [ capability ]
    } ]);
    // Report the robustness actually granted, which can be weaker than asked.
    const granted = access.getConfiguration().videoCapabilities?.[0]?.robustness;
    return { text: granted ? 'Granted (' + granted + ')' : 'Granted', good: true };
  } catch (error) {
    // A rejection is the normal answer with no CDM installed, so the name
    // matters more than the fact of failing: NotSupportedError means "no such
    // key system", which is what an unregistered Widevine looks like.
    return { text: (error && error.name) ? error.name : String(error), good: false };
  }
}

async function fillWidevineTable() {
  const table = document.getElementById('widevine-table');
  if (!table) return;
  for (const entry of kKeySystems) {
    const result = await probeKeySystem(entry);
    const row = tableBody(table).insertRow();
    const name = document.createElement('th');
    name.innerText = entry.label;
    name.title = entry.system + (entry.robustness ? ' / ' + entry.robustness : '');
    row.appendChild(name);
    const cell = row.insertCell();
    cell.innerText = result.text;
    cell.classList.add(result.good ? 'yes' : 'no');
  }
}

// --- WebGL -----------------------------------------------------------------

function fillWebGl() {
  const canvas = document.createElement('canvas');
  let gl = null;
  try {
    gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
  } catch (error) {
    replaceVerdict('webgl-status', 'threw: ' + error, false);
    return;
  }
  if (!gl) {
    replaceVerdict('webgl-status', 'Unavailable', false);
    return;
  }
  replaceVerdict('webgl-status', 'Available', true);

  // The plain VENDOR/RENDERER strings are masked to a generic value; the real
  // driver name needs this extension, which is what distinguishes a D3D9
  // device from SwiftShader.
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  const renderer = info
    ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL)
    : gl.getParameter(gl.RENDERER) + ' (masked)';
  replaceText('webgl-renderer', renderer);
  replaceText('webgl-vendor', info
    ? gl.getParameter(info.UNMASKED_VENDOR_WEBGL)
    : gl.getParameter(gl.VENDOR) + ' (masked)');
  replaceText('webgl-version', gl.getParameter(gl.VERSION));

  // Inferred from the renderer string, because a page has no direct way to
  // ask. Chromium names the software rasterizers in it, so this is reliable in
  // the direction that matters -- spotting a silent fall back to SwiftShader --
  // but it has to say so rather than claim to have measured it. chrome://gpu
  // is the authority.
  if (!info) {
    replaceText('webgl-hw', 'Unknown: (renderer string is masked)');
  } else {
    const software = /swiftshader|software|llvmpipe|basic render/i.test(renderer);
    replaceVerdict('webgl-hw',
      software ? 'No, software rasterizer' : 'Yes, by renderer name', !software);
  }

  let gl2 = null;
  try {
    gl2 = document.createElement('canvas').getContext('webgl2');
  } catch {
    gl2 = null;
  }
  replaceVerdict('webgl2-status', gl2 ? 'Available' : 'Unavailable', !!gl2);
}

// --- Main process facts ----------------------------------------------------

async function fillFromMainProcess() {
  try {
    const facts = await ipcRenderer.invoke('get-test-facts');

    replaceText('app-version', facts.appVersion);
    replaceText('os-release', facts.osRelease);
    replaceText('node-abi', facts.nodeAbi);
    replaceText('command-line', facts.commandLine.join('\n'));

    if (facts.aeroGlass === null) {
      replaceText('aero-glass', 'N/A (not Windows)');
    } else if (typeof facts.aeroGlass === 'string') {
      replaceVerdict('aero-glass', 'missing: ' + facts.aeroGlass, false);
    } else {
      replaceVerdict('aero-glass', String(facts.aeroGlass), true);
    }

    replaceText('cdm-path', facts.widevineCdmPath || 'Not requested');
    if (facts.widevineCdmPath) {
      replaceVerdict('cdm-present', facts.widevineCdmPresent,
        facts.widevineCdmPresent.startsWith('Yes'));
    } else {
      replaceText('cdm-present', 'N/A');
    }

    if (facts.nativeModule.loaded) {
      replaceVerdict('native-module', 'Loaded .node (' + facts.nativeModule.detail + ')', true);
    } else {
      replaceVerdict('native-module', 'Failed: ' + facts.nativeModule.detail, false);
    }
  } catch (error) {
    console.error('Could not read the main process facts: ' + error);
  }
}

window.addEventListener('DOMContentLoaded', async () => {
  // Show version numbers of bundled Electron
  for (const dependency of [ 'electron', 'chrome', 'node', 'v8' ]) {
    replaceText(`${dependency}-version`, process.versions[dependency]);
  }
  replaceText('os-type', osType);
  replaceText('arch-type', process.arch);
  // process.sandboxed is set in a sandboxed renderer; absent means it is not.
  replaceVerdict('sandboxed', process.sandboxed ? 'Yes' : 'No', !!process.sandboxed);

  fillCodecTable();
  fillWebGl();
  await fillFromMainProcess();
  // Last, and awaited: every row is a promise the browser may take a moment
  // over, and a rejection here must not stop the rest of the page filling in.
  await fillWidevineTable();

  ipcRenderer.invoke('finished-preload');
});

console.log('electron.renderer: Electron versions exported');
