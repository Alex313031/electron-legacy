async function test_media() {
  const types = [
    ['H.264 High',            'video/mp4; codecs="avc1.640028"'],
    ['HEVC Main L3.1',        'video/mp4; codecs="hvc1.1.6.L93.B0"'],
    ['HEVC Main L3.1 (hev1)', 'video/mp4; codecs="hev1.1.6.L93.B0"'],
    ['HEVC Main10 L4',        'video/mp4; codecs="hvc1.2.4.L120.B0"'],
    ['HEVC Main L5.1 (4K)',   'video/mp4; codecs="hvc1.1.6.L153.B0"'],
    ['AAC-LC',                'audio/mp4; codecs="mp4a.40.2"'],
    ['AC-3',                  'audio/mp4; codecs="ac-3"'],
    ['AC-3 (mp4a.A5)',        'audio/mp4; codecs="mp4a.A5"'],
    ['E-AC-3',                'audio/mp4; codecs="ec-3"'],
    ['E-AC-3 (mp4a.A6)',      'audio/mp4; codecs="mp4a.A6"'],
  ];
  const el = document.createElement('video');
  const rows = [];
  for (const [name, type] of types) {
    const isVideo = type.startsWith('video/');
    const cfg = { type: 'file' };
    cfg[isVideo ? 'video' : 'audio'] = isVideo
      ? { contentType: type, width: 1920, height: 1080, bitrate: 5e6, framerate: 30 }
      : { contentType: type, channels: '6', bitrate: 448000, samplerate: 48000 };
    let caps;
    try { caps = await navigator.mediaCapabilities.decodingInfo(cfg); }
    catch (e) { caps = { supported: 'threw: ' + e.message }; }
    rows.push({
      codec: name,
      isTypeSupported: MediaSource.isTypeSupported(type),
      canPlayType: el.canPlayType(type) || '(empty = no)',
      decodingInfo: caps.supported,
      smooth: caps.smooth,
      powerEfficient: caps.powerEfficient,
    });
  }
  console.table(rows);
};

test_media();
