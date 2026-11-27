// Renders QA screenshots of the previewer with headless Chromium.
//   node tools/preview/shoot.mjs --out <dir> --views "<spec>" [--poses file] [--frames 0,10,20] [--grid N]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const here = path.dirname(fileURLToPath(import.meta.url));
const kitRoot = path.resolve(here, '..', '..');

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, arr) => {
  if (a.startsWith('--')) acc.push([a.slice(2), arr[i + 1] && !arr[i + 1].startsWith('--') ? arr[i + 1] : '1']);
  return acc;
}, []));

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json', '.png': 'image/png', '.glb': 'model/gltf-binary' };
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = path.join(kitRoot, url.startsWith('/node_modules') ? url : path.join('tools/preview', url));
  if (!file.startsWith(kitRoot) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

const outDir = path.resolve(args.out || path.join(here, 'out', 'shots'));
fs.mkdirSync(outDir, { recursive: true });
const w = +(args.w || 900), h = +(args.h || 900);
const qs = new URLSearchParams({ w, h, views: args.views || 'front:0,3.4,-9:0,2.8,0:32' });
if (args.poses) qs.set('poses', args.poses);
if (args.model) qs.set('model', args.model);
if (args.follow) qs.set('follow', '1');
if (args.ground) qs.set('ground', args.ground);
if (args.exposure) qs.set('exposure', args.exposure);
if (args.grid) qs.set('grid', '1');
if (args.orient) qs.set('orient', '1');
if (args.glb) qs.set('glb', args.glb);

const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
page.on('console', (m) => { if (m.type() === 'error') console.error('[page]', m.text()); });
page.on('pageerror', (e) => console.error('[pageerror]', e.message));
await page.goto(`http://127.0.0.1:${port}/qa.html?${qs}`);
await page.waitForFunction(() => window.ready === true, null, { timeout: 120000 });
const viewCount = await page.evaluate(() => window.viewCount);
const frameCount = await page.evaluate(() => window.frameCount);
const frames = args.frames ? args.frames.split(',').map(Number) : [0];
const prefix = args.prefix || 'shot';
const written = [];
for (let v = 0; v < viewCount; v++) {
  for (const f of frames) {
    if (f >= frameCount) continue;
    await page.evaluate(([vi, fi]) => window.renderView(vi, fi), [v, f]);
    const file = path.join(outDir, `${prefix}_v${v}_f${String(f).padStart(4, '0')}.png`);
    await page.locator('canvas').screenshot({ path: file });
    written.push(file);
  }
}
await browser.close();
server.close();
console.log(written.join('\n'));
