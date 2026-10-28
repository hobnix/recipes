/* eslint-disable */
// Tdarr classic plugin of the homeserver (hs recipe tdarr): make a film easy for Jellyfin.
//
//  1. Audio: a language whose only tracks are TrueHD / DTS / DTS-HD / MLP (browsers and many
//     TVs can't play them, so Jellyfin has to convert on the fly) gets an extra AC3 track.
//     The extra track goes FIRST and is the default one, so Jellyfin picks it; the original
//     track stays after it, untouched.
//  2. Video: kept bit for bit (-c:v copy). Only a format that Jellyfin can hardly show at all
//     (old MPEG-4/DivX/Xvid, WMV, VC-1, MPEG-1/2, ... or H.264 10-bit / 4:2:2 / 4:4:4) is converted
//     to H.264 at high quality (NVENC when the NVIDIA card is in the container, else x264).
//  3. Container: anything that is not .mkv or .mp4 (avi, ts, m2ts, wmv, ...) becomes .mkv, no re-encoding.
//  4. Originals: before a file is changed, a hard link to it is made under
//     <originalsDir>/<same path>. Tdarr replaces the file by writing a new one, the old data
//     lives on in the link. No link (e.g. the link fails) = the file is left alone.
//
// Nothing here asks the disk for more than ffprobe's data Tdarr already has, so scanning is cheap.
const fs = require('fs');
const path = require('path');

const details = () => ({
  id: 'Tdarr_Plugin_hs_Jellyfin_Friendly',
  Stage: 'Pre-processing',
  Name: 'Homeserver: make it easy for Jellyfin',
  Type: 'Video',
  Operation: 'Transcode',
  Description: 'Adds an AC3 track (first, default) next to TrueHD/DTS-only audio, keeps the video untouched '
    + 'unless Jellyfin could hardly show it, remuxes odd containers to mkv, keeps a hard link of the original.',
  Version: '1.00',
  Tags: 'pre-processing,ffmpeg,audio,jellyfin',
  Inputs: [
    {
      name: 'originalsDir',
      type: 'string',
      defaultValue: '/media/_tdarr-originals',
      inputUI: { type: 'text' },
      tooltip: 'Folder (on the same disk as the films) for the hard links of the originals. Empty = no backup (not recommended).',
    },
    {
      name: 'libraryRoot',
      type: 'string',
      defaultValue: '/media',
      inputUI: { type: 'text' },
      tooltip: 'The part of the path that is dropped when the original is put in the folder above.',
    },
    {
      name: 'addAac',
      type: 'boolean',
      defaultValue: false,
      inputUI: { type: 'dropdown', options: ['false', 'true'] },
      tooltip: 'Also add an AAC stereo track (plays in every browser without converting). Default false: AC3 only.',
    },
  ],
});

// ffprobe names: truehd, mlp, dts (also DTS-HD MA / HRA / X)
const BAD_AUDIO = ['truehd', 'mlp', 'dts', 'dca'];
const OK_AUDIO = ['ac3', 'eac3', 'aac'];
// video that is worth converting
const OLD_VIDEO = ['mpeg4', 'msmpeg4v1', 'msmpeg4v2', 'msmpeg4v3', 'wmv1', 'wmv2', 'wmv3', 'vc1', 'mpeg1video',
  'mpeg2video', 'flv1', 'h263', 'rv10', 'rv20', 'rv30', 'rv40', 'cinepak', 'indeo3', 'indeo4', 'indeo5', 'vp6', 'vp6f', 'theora'];
const GOOD_CONTAINERS = ['mkv', 'mp4', 'm4v'];

const lang = (s) => ((s.tags && (s.tags.language || s.tags.LANGUAGE)) || 'und').toLowerCase();
const isDefault = (s) => !!(s.disposition && s.disposition.default === 1);

const hasNvidia = () => {
  try { return fs.existsSync('/dev/nvidia0') || fs.existsSync('/dev/nvidiactl'); } catch (e) { return false; }
};

const plugin = (file, librarySettings, inputs) => {
  const response = {
    processFile: false,
    preset: '',
    container: `.${file.container}`,
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: true,
    infoLog: '',
  };
  const opt = (k, d) => (inputs && inputs[k] !== undefined && inputs[k] !== '' ? inputs[k] : d);
  const originalsDir = inputs && inputs.originalsDir !== undefined ? inputs.originalsDir : '/media/_tdarr-originals';
  const libraryRoot = opt('libraryRoot', '/media');
  const addAac = String(opt('addAac', false)) === 'true';

  if (file.fileMedium !== 'video' || !file.ffProbeData || !Array.isArray(file.ffProbeData.streams)) {
    response.infoLog += 'Not a video file, skipped. ';
    return response;
  }
  const streams = file.ffProbeData.streams;
  const videos = streams.filter((s) => s.codec_type === 'video' && !(s.disposition && s.disposition.attached_pic === 1));
  const audios = streams.filter((s) => s.codec_type === 'audio');
  if (videos.length === 0) {
    response.infoLog += 'No video stream, skipped. ';
    return response;
  }

  // ── audio: which languages have only unplayable tracks? ──
  const byLang = {};
  audios.forEach((s) => { (byLang[lang(s)] = byLang[lang(s)] || []).push(s); });
  const sources = [];   // one source track per language that needs help (the best one: most channels)
  Object.keys(byLang).forEach((l) => {
    const list = byLang[l];
    if (list.some((s) => OK_AUDIO.includes(s.codec_name))) return;
    const bad = list.filter((s) => BAD_AUDIO.includes(s.codec_name));
    if (bad.length === 0) return;
    bad.sort((a, b) => (b.channels || 0) - (a.channels || 0));
    sources.push(bad[0]);
  });
  // the language of the default (else first) track comes first
  const firstTrack = audios.find(isDefault) || audios[0];
  sources.sort((a, b) => (lang(b) === lang(firstTrack)) - (lang(a) === lang(firstTrack)));

  // ── video ──
  const mainVideo = videos[0];
  const bits = parseInt(mainVideo.bits_per_raw_sample || '0', 10);
  const pix = mainVideo.pix_fmt || '';
  const hard264 = mainVideo.codec_name === 'h264'
    && (bits > 8 || /10le|10be|422|444|411|440/.test(pix));
  const convertVideo = OLD_VIDEO.includes(mainVideo.codec_name) || hard264;

  const badContainer = !GOOD_CONTAINERS.includes(String(file.container).toLowerCase());

  if (sources.length === 0 && !convertVideo && !badContainer) {
    response.infoLog += 'Already fine for Jellyfin. ';
    return response;
  }

  // ── backup of the original (hard link) ──
  if (originalsDir) {
    try {
      const rel = path.relative(libraryRoot, file._id);
      if (rel.startsWith('..')) throw new Error(`${file._id} is not under ${libraryRoot}`);
      const dest = path.join(originalsDir, rel);
      let have = false;
      try { have = fs.statSync(dest).ino === fs.statSync(file._id).ino; } catch (e) { have = false; }
      if (!have) {
        if (fs.existsSync(dest)) throw new Error(`${dest} exists already (another file)`);
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.linkSync(file._id, dest);
      }
    } catch (e) {
      response.infoLog += `Left alone, no backup possible: ${e.message}. `;
      return response;
    }
  }

  // ── build the ffmpeg arguments (output part, after the input) ──
  let cmd = ', -map 0:v';
  const added = sources;
  // new tracks first, one -map each, then every original track
  let n = 0;                      // output audio index
  let opts = '';
  added.forEach((s) => {
    const idx = audios.indexOf(s);
    const ch = Math.min(s.channels || 2, 6);
    const kbps = ch >= 6 ? 640 : (ch >= 3 ? 448 : 192);
    cmd += ` -map 0:a:${idx}`;
    opts += ` -c:a:${n} ac3 -b:a:${n} ${kbps}k -ac:a:${n} ${ch}`
      + ` -metadata:s:a:${n} title=AC3-${ch === 6 ? '5.1' : (ch === 2 ? '2.0' : `${ch}ch`)}-Jellyfin`
      + ' -disposition:a:' + n + (n === 0 ? ' default' : ' 0');
    n += 1;
    if (addAac) {
      cmd += ` -map 0:a:${idx}`;
      opts += ` -c:a:${n} aac -b:a:${n} 256k -ac:a:${n} 2`
        + ` -metadata:s:a:${n} title=AAC-2.0-Browser -disposition:a:${n} 0`;
      n += 1;
    }
  });
  if (audios.length > 0) cmd += ' -map 0:a';
  if (added.length > 0) {
    // the originals lose the default flag (the new first track carries it)
    audios.forEach((s, i) => { opts += ` -disposition:a:${n + i} 0`; });
  }
  cmd += ' -map 0:s? -map 0:t?';

  // video options
  if (convertVideo) {
    if (hasNvidia()) {
      opts += ' -c:v:0 h264_nvenc -preset p6 -tune hq -rc vbr -cq 19 -b:v 0 -profile:v high -pix_fmt yuv420p';
    } else {
      opts += ' -c:v:0 libx264 -preset slow -crf 18 -profile:v high -pix_fmt yuv420p';
    }
  }
  // everything not named above is copied (a specific option such as -c:a:0 beats -c copy)
  cmd += ` -c copy${opts} -max_muxing_queue_size 9999`;

  if (badContainer) response.container = '.mkv';
  response.preset = cmd;
  response.processFile = true;
  response.infoLog += [
    added.length ? `Adding AC3${addAac ? '+AAC' : ''} for: ${added.map((s) => `${lang(s)}/${s.codec_name}`).join(', ')}. ` : '',
    convertVideo ? `Converting ${mainVideo.codec_name} (${pix}) to H.264. ` : '',
    badContainer ? `Remuxing ${file.container} to mkv. ` : '',
  ].join('');
  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
