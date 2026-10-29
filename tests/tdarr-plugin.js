// Test of recipes/tdarr/Tdarr_Plugin_hs_Jellyfin_Friendly.js against real ffmpeg.
// Run through tests/tdarr-plugin.sh (needs node, ffmpeg, ffprobe).
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const assert = require('assert');

const plugin = require('../recipes/tdarr/Tdarr_Plugin_hs_Jellyfin_Friendly.js');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tdarr-'));
const lib = path.join(tmp, 'media');
const orig = path.join(tmp, 'originals');
fs.mkdirSync(path.join(lib, 'movies'), { recursive: true });

const ff = (...a) => execFileSync('ffmpeg', ['-v', 'error', '-y', ...a], { stdio: 'pipe' });
const probe = (f) => JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-print_format', 'json', '-show_streams', '-show_format', f]).toString());
const fileObj = (f) => {
  const p = probe(f);
  return { _id: f, fileMedium: 'video', container: path.extname(f).slice(1), ffProbeData: p };
};
const run = (f, extra = {}) => plugin.plugin(fileObj(f), {}, { originalsDir: orig, libraryRoot: lib, ...extra });
// what Tdarr does with the preset: input, preset split on spaces, output
const apply = (f, r) => {
  const out = path.join(tmp, `out${r.container}`);
  const args = r.preset.split(',').pop().trim().split(/\s+/);
  ff('-i', f, ...args, out);
  return probe(out);
};
const codecs = (p, t) => p.streams.filter((s) => s.codec_type === t).map((s) => `${s.codec_name}/${(s.tags || {}).language || 'und'}/${s.channels || ''}${s.disposition.default ? '/default' : ''}`);

// 1. English TrueHD 5.1 (default) + German DTS stereo, H.264 video
const a = path.join(lib, 'movies', 'a.mkv');
ff('-f', 'lavfi', '-i', 'testsrc=d=2:s=320x240:r=24', '-f', 'lavfi', '-i', 'sine=d=2', '-f', 'lavfi', '-i', 'sine=f=600:d=2',
  '-map', '0', '-map', '1', '-map', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a:0', 'truehd', '-strict', '-2', '-ac:a:0', '6',
  '-c:a:1', 'dts', '-strict', '-2', '-ac:a:1', '2', '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=ger',
  '-disposition:a:0', 'default', a);
let r = run(a);
assert.strictEqual(r.processFile, true, r.infoLog);
assert.ok(fs.existsSync(path.join(orig, 'movies', 'a.mkv')), 'hard link of the original');
assert.strictEqual(fs.statSync(path.join(orig, 'movies', 'a.mkv')).ino, fs.statSync(a).ino);
let p = apply(a, r);
assert.deepStrictEqual(codecs(p, 'audio'), ['ac3/eng/6/default', 'ac3/ger/2', 'truehd/eng/6', 'dts/ger/2']);
assert.deepStrictEqual(codecs(p, 'video'), ['h264/und/']);
// the result needs nothing more
const done = path.join(lib, 'movies', 'done.mkv');
fs.copyFileSync(path.join(tmp, 'out.mkv'), done);
r = run(done);
assert.strictEqual(r.processFile, false, 'finished file is left alone');

// 1b. with the AAC track too
r = run(a, { addAac: 'true' });
p = apply(a, r);
assert.deepStrictEqual(codecs(p, 'audio').slice(0, 4), ['ac3/eng/6/default', 'aac/eng/2', 'ac3/ger/2', 'aac/ger/2']);

// 2. old AVI (mpeg4 + mp3) becomes mkv with H.264
const avi = path.join(lib, 'movies', 'old.avi');
ff('-f', 'lavfi', '-i', 'testsrc=d=2:s=320x240:r=24', '-f', 'lavfi', '-i', 'sine=d=2', '-c:v', 'mpeg4', '-c:a', 'mp3', avi);
r = run(avi);
assert.strictEqual(r.processFile, true);
assert.strictEqual(r.container, '.mkv');
p = apply(avi, r);
assert.deepStrictEqual(codecs(p, 'video'), ['h264/und/']);

// 3. a good file is not touched, nothing is linked
const good = path.join(lib, 'movies', 'good.mp4');
ff('-f', 'lavfi', '-i', 'testsrc=d=2:s=320x240:r=24', '-f', 'lavfi', '-i', 'sine=d=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', good);
r = run(good);
assert.strictEqual(r.processFile, false);
assert.ok(!fs.existsSync(path.join(orig, 'movies', 'good.mp4')));

// 4. no backup possible = file is left alone
const blocked = path.join(tmp, 'blocked');
fs.writeFileSync(blocked, 'a file, not a folder');
r = plugin.plugin(fileObj(a), {}, { originalsDir: path.join(blocked, 'x'), libraryRoot: lib });
assert.strictEqual(r.processFile, false);
assert.match(r.infoLog, /no backup possible/);

// 5. a different file already holds the backup name
fs.mkdirSync(path.join(orig, 'movies'), { recursive: true });
const b = path.join(lib, 'movies', 'b.avi');
fs.copyFileSync(avi, b);
fs.writeFileSync(path.join(orig, 'movies', 'b.avi'), 'something else');
r = run(b);
assert.strictEqual(r.processFile, false);

fs.rmSync(tmp, { recursive: true, force: true });
console.log('tdarr plugin: all checks passed');
