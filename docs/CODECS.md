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

For encrypted media streams (i.e. Netflix, Hulu), a component called [Widevine](https://www.widevine.com/).
