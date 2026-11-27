// Offline Luau harness: runs SpiderHeroKit sources in the real Luau VM (WASM build of upstream Luau)
// with Roblox datatype shims and a mock DataModel so the builder, rig math and animation runtime
// can be tested and baked without Roblox Studio.
//
//   node tools/harness/run.mjs <script.luau> [args...]
//
import { Lua } from '@luau-rs/luau';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const kitRoot = path.resolve(here, '..', '..');

export async function createHarness() {
  const lua = await Lua.create({ sandbox: false });
  const g = lua.globals;
  g.set('print', lua.createFunction((...a) => { console.log(a.map((x) => String(x)).join('\t')); }));
  g.set('__readfile', lua.createFunction((p) => fs.readFileSync(String(p), 'utf8')));
  g.set('__exists', lua.createFunction((p) => fs.existsSync(String(p))));
  g.set('__writefile', lua.createFunction((p, content) => {
    fs.mkdirSync(path.dirname(String(p)), { recursive: true });
    fs.writeFileSync(String(p), String(content));
  }));
  g.set('__listdir', lua.createFunction((p) => {
    const entries = fs.readdirSync(String(p), { withFileTypes: true })
      .filter((e) => !e.name.startsWith('.'))
      .sort((a, b) => a.name.localeCompare(b.name))
      .map((e) => lua.createTable({ name: e.name, dir: e.isDirectory() }));
    return lua.createTable(entries);
  }));
  g.set('__load', lua.createFunction((src, name, env) => lua.load(String(src), { name: String(name), environment: env })));
  g.set('__kitRoot', kitRoot);
  const bootstrap = fs.readFileSync(path.join(here, 'env.luau'), 'utf8');
  lua.execute(bootstrap, { name: '@tools/harness/env.luau' });
  return lua;
}

export function runFile(lua, file, args = []) {
  const abs = path.resolve(file);
  const src = fs.readFileSync(abs, 'utf8');
  const argTable = lua.createTable(args.map(String));
  lua.globals.set('__args', argTable);
  const fn = lua.globals.get('__runScript');
  return fn.call(src, '@' + path.relative(kitRoot, abs));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [file, ...args] = process.argv.slice(2);
  if (!file) {
    console.error('usage: node tools/harness/run.mjs <script.luau> [args...]');
    process.exit(2);
  }
  const lua = await createHarness();
  try {
    runFile(lua, file, args);
  } catch (e) {
    console.error(e && e.message ? e.message : e);
    if (e && e.stack && process.env.HARNESS_JS_STACK) console.error(e.stack);
    process.exit(1);
  }
}
