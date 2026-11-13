# Codecs

Doc explaining proprietary codecs in Electron, and the added codecs this fork adds.

## HEVC/AC3

Chromium builds ffmpeg with a deliberately narrow codec set and leaves HEVC, AC-3, E-AC-3 and
MPEG-2 to the platform — a hardware decoder, or nothing. On legacy Windows that generally means
nothing. `patches/other/12` and `patches/other/13` build those decoders into ffmpeg and fall back
to them when no hardware decoder answers, which is what Chromium already does for H.264, MP3, VP8, VP9
and AV1. These are decoders only; nothing here encodes.

Confirmed playing on real Windows 7:

| Codec | Accepted as |
|---|---|
| HEVC / H.265, Main and Main 10 | `hvc1.*`, `hev1.*` in mp4 |
| AC-3 (Dolby Digital) | `ac-3`, `mp4a.A5` in mp4 and mkv |
| E-AC-3 (Dolby Digital Plus) | `ec-3`, `mp4a.A6` in mp4 and mkv |
| MPEG-2 video | rides along with the AC-3 patch |

Hardware HEVC decoding is still preferred where the platform offers it
(`enable_hevc_parser_and_hw_decoder`); the patches only remove the requirement. HEVC *encoding*
stays off (`platform_has_optional_hevc_encode_support = false`), as legacy Windows has no encoder
to offer.

To check a build yourself, paste [assets/media-test.js](../assets/media-test.js) into the DevTools
console of any Electron window. It prints a table of `MediaSource.isTypeSupported`,
`canPlayType` and `mediaCapabilities.decodingInfo` for each codec above, which is more useful than
a video that silently fails to play.

## Widevine

For encrypted media streams (i.e. Netflix, Hulu), a component called
[Widevine](https://www.widevine.com/) does the decrypting. It is a CDM (Content Decryption Module)
— a closed-source library Chrome loads and the page drives through
[EME](https://developer.mozilla.org/en-US/docs/Web/API/Encrypted_Media_Extensions_API). Codecs and
the CDM are separate problems: the codecs above decide whether a stream can be *decoded*, Widevine
decides whether it can be *decrypted* first. A DRM site needs both.

Upstream Electron cannot load one at all — `enable_widevine` defaults to false outside Chrome
branding, so the host side was never compiled. `patches/other/14` revives it and
`assets/args/**/*.gn` set `enable_widevine = true`.

### Supplying a CDM

No CDM is bundled and none is downloaded. Google does not redistribute it freely, and Electron has
no component updater to fetch it with (`BrowserProcessImpl::component_updater()` returns
`nullptr`), so the binary has to be pointed at one:

```sh
electron.exe --widevine-cdm-path="C:\path\to\WidevineCdm" .
```

Nothing is registered without that flag, so a build nobody points at a CDM behaves exactly as it
did before. Two directory layouts work:

| Layout | Contents | Version from |
|---|---|---|
| Component (preferred) | `manifest.json` at the top, library under `_platform_specific/win_x64\|win_x86/` | `manifest.json` |
| Flat | just `widevinecdm.dll` | `--widevine-cdm-version` |

The component layout is what Chrome itself leaves on disk, so the easiest source of a CDM is a
Chrome install — `Google\Chrome\Application\<version>\WidevineCdm` for the bundled copy, or
`Google\Chrome\User Data\WidevineCdm\<version>` for a component-updated one. Prefer it: the
manifest is read with the same parser Chrome uses, so the codecs, encryption schemes and version
all come from the CDM rather than being assumed, and `--widevine-cdm-version` becomes unnecessary.

Match the architecture. A 32-bit Electron needs the `win_x86` CDM out of a 32-bit Chrome; the
`win_x64` one will not load into it.

### Security levels, and why Netflix will still refuse

Widevine grades clients L3 (software), L2 and L1 (increasing hardware protection), and a client is
only trusted above L3 if its executables carry a VMP (Verified Media Path) signature. Signing
needs certificates Google issues to licensees, and Chromium only wires up the signing step for
Chrome-branded builds — `enable_widevine_cdm_host_verification` requires `is_chrome_branded`, so
it stays off here. Nothing in this repo is signed.

The practical upshot: this is **L3 only**. Sites that accept L3 should play; sites that demand L1
or L2 for anything above SD — Netflix among them — are expected to refuse, and that is a licensing
decision rather than something a patch can fix. If you need real VMP signing, that is what
[castlabs' Electron fork](https://github.com/castlabs/electron-releases) exists for.

Sessions are temporary-only, and persistent licenses are not offered: that needs both a CDM built
to store them and somewhere to keep them, and neither is arranged here.

### Checking it loaded

`--widevine-cdm-path` pointing somewhere wrong is quiet by design — the CDM is simply not
registered — so check from the DevTools console rather than guessing:

```js
navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{
  initDataTypes: ['cenc'],
  videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.640028"' }],
}]).then(a => console.log('Widevine available:', a.keySystem))
   .catch(e => console.log('Widevine unavailable:', e.name, e.message));
```

Run Electron with `--enable-logging` if that rejects: a CDM that was found but unusable logs why
(no library beside the manifest, a manifest too old for this build, a missing or malformed
`--widevine-cdm-version`).

> **Status:** the host side compiles, but this has not yet been verified end to end on legacy
> Windows the way the codecs above have. Expect rough edges.
