#!/usr/bin/env node
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';

const VERSION = '0.1.0';
const IS_WIN = process.platform === 'win32';

const readJson = (f, d) => {
  let s;
  try { s = fs.readFileSync(f, 'utf8').replace(/^﻿/, ''); } catch { return d; }
  try { return JSON.parse(s); } catch (e) { if (f === TODOS) throw new Error('todos.json is not valid JSON, refusing to overwrite it: ' + e.message); return d; }
};

const DATA = process.env.CC_REMIND_DATA || (IS_WIN
  ? path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'cc-remind')
  : path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'cc-remind'));
const CONFIG_FILE = path.join(DATA, 'config.json');
const TODOS = path.join(DATA, 'todos.json');
const CACHE = path.join(DATA, 'scan-cache.json');
const LOCK = path.join(DATA, 'todos.lock');
const CFG = readJson(CONFIG_FILE, {}) || {};
const CLAUDE_DIR = process.env.CLAUDE_CONFIG_DIR || CFG.claudeConfigDir || path.join(os.homedir(), '.claude');
const PROJECTS = path.join(CLAUDE_DIR, 'projects');
const LIVE_DIR = path.join(CLAUDE_DIR, 'sessions');
const JUNK = /[\\/](Windows|AppData|Temp)([\\/]|$)|^[A-Z]:[\\/]temp$|^\/(tmp|var\/folders)([\\/]|$)/i;
const STALE_DAYS = 14;
const HOOK_CAP = 8;
const CLOSE_SKILLS = Array.isArray(CFG.closeSkills) ? CFG.closeSkills.filter(s => typeof s === 'string' && s) : [];
const LANG = ['en', 'th'].includes(process.env.CC_REMIND_LANG || CFG.language) ? (process.env.CC_REMIND_LANG || CFG.language) : 'en';

const TZ = (() => {
  const z = process.env.CC_REMIND_TZ || CFG.timeZone;
  if (z) { try { new Intl.DateTimeFormat('en-US', { timeZone: z }); return z; } catch { console.error(`cc-remind: unknown time zone "${z}", using the system time zone`); } }
  return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
})();
const DTF = new Intl.DateTimeFormat('en-US', { timeZone: TZ, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
function zparts(ms) { const p = {}; for (const x of DTF.formatToParts(new Date(ms))) p[x.type] = x.value; return { y: +p.year, mo: +p.month, d: +p.day, h: +p.hour % 24, mi: +p.minute, s: +p.second }; }
const tzOffset = ms => { const p = zparts(ms); return Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s) - Math.floor(ms / 1000) * 1000; };
function zoned(y, mo, d, h, mi) {
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  const t = guess - tzOffset(guess);
  return guess - tzOffset(t);
}
const pad = n => String(n).padStart(2, '0');
const fmtTime = iso => { const p = zparts(Date.parse(iso)); return `${p.y}-${pad(p.mo)}-${pad(p.d)} ${pad(p.h)}:${pad(p.mi)}`; };

const MSG = {
  en: { due: 'Due: ', from: 'From ', closed: 'Closed: ', by: 'by the chat in ' },
  th: { due: 'ถึงเวลา: ', from: 'จาก ', closed: 'ปิดแล้ว: ', by: 'โดยแชท ' },
}[LANG];

fs.mkdirSync(DATA, { recursive: true });

const writeJson = (f, v) => { const t = f + '.' + process.pid + '.tmp'; fs.writeFileSync(t, JSON.stringify(v, null, 1)); fs.renameSync(t, f); };
const norm = p => (p || '').replace(/[\\/]+$/, '').toLowerCase();
const leaf = p => (p || '').replace(/[\\/]+$/, '').split(/[\\/]/).pop();
const under = (child, parent) => child === parent || child.startsWith(parent + '\\') || child.startsWith(parent + '/');
const sleep = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function withLock(fn) {
  const until = Date.now() + 5000;
  for (;;) {
    try { fs.writeFileSync(LOCK, String(process.pid), { flag: 'wx' }); break; }
    catch {
      try { if (Date.now() - fs.statSync(LOCK).mtimeMs > 10000) fs.unlinkSync(LOCK); } catch {}
      if (Date.now() > until) throw new Error('todos.json is locked, try again');
      sleep(50);
    }
  }
  try { const db = readJson(TODOS, { items: [] }); const r = fn(db); writeJson(TODOS, db); return r; }
  finally { try { fs.unlinkSync(LOCK); } catch {} }
}

function alive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }

function liveSessions() {
  const m = {};
  let files = [];
  try { files = fs.readdirSync(LIVE_DIR).filter(f => /^\d+\.json$/.test(f)); } catch {}
  for (const f of files) {
    const j = readJson(path.join(LIVE_DIR, f), null);
    if (j && j.sessionId && alive(j.pid)) m[j.sessionId] = { pid: j.pid, cwd: j.cwd };
  }
  return m;
}

const RX_CWD = /"cwd":"((?:[^"\\]|\\.)*)"/;
const RX_TITLE = /"aiTitle":"((?:[^"\\]|\\.)*)"/;
const unq = s => { try { return JSON.parse('"' + s + '"'); } catch { return s; } };
const CLOSE_NAMES = ['compact', ...CLOSE_SKILLS];
const RX_CLOSE_TEXT = new RegExp('(^|\\s)/(' + CLOSE_NAMES.map(n => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|') + ')(\\s|$)');

function scanLine(st, l) {
  if (!st.cwd) { const m = l.match(RX_CWD); if (m) st.cwd = unq(m[1]); }
  if (l.startsWith('{"type":"ai-title"')) { const m = l.match(RX_TITLE); if (m) st.title = unq(m[1]); return; }
  if (l.includes('"subtype":"compact_boundary"')) st.compacts++;
  for (const n of CLOSE_SKILLS) if (l.includes(`"name":"Skill","input":{"skill":"${n}"`)) st.closed = true;
  const k = l.indexOf('"message":{"role":"user","content":"');
  if (k >= 0 && l.includes('"type":"user"')) {
    const c = l.slice(k + 36, k + 36 + 400);
    if (CLOSE_NAMES.some(n => c.includes(`<command-name>/${n}</command-name>`))) { st.closed = true; return; }
    if (c.startsWith('<') || c.startsWith('This session is being continued')) return;
    const txt = c.split(/"},"|","/)[0];
    if (RX_CLOSE_TEXT.test(txt)) st.closed = true;
    else if (txt.length > 30) st.closed = false;
    if (!st.first) st.first = unq(txt.replace(/\\u[0-9a-fA-F]{0,3}$|\\$/, '')).slice(0, 80);
  }
}

function scanFile(file, prev) {
  const stat = fs.statSync(file);
  const st = prev && prev.size <= stat.size && prev.ino === String(stat.ino) ? prev
    : { cwd: null, title: null, first: null, compacts: 0, closed: false, offset: 0, ino: String(stat.ino) };
  if (st.offset < stat.size) {
    const fd = fs.openSync(file, 'r');
    try {
      const len = stat.size - st.offset;
      const buf = Buffer.alloc(len);
      fs.readSync(fd, buf, 0, len, st.offset);
      const lastNl = buf.lastIndexOf(10);
      if (lastNl >= 0) {
        for (const l of buf.subarray(0, lastNl).toString('utf8').split('\n')) scanLine(st, l);
        st.offset += lastNl + 1;
      }
    } finally { fs.closeSync(fd); }
  }
  st.size = stat.size; st.mtime = stat.mtimeMs;
  return st;
}

function scanSessions() {
  const cache = readJson(CACHE, {});
  const next = {};
  const out = [];
  let dirs = [];
  try { dirs = fs.readdirSync(PROJECTS, { withFileTypes: true }); } catch {}
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const dir = path.join(PROJECTS, d.name);
    let files = [];
    try { files = fs.readdirSync(dir); } catch { continue; }
    for (const f of files) {
      if (!f.endsWith('.jsonl')) continue;
      const file = path.join(dir, f);
      let st;
      try { st = scanFile(file, cache[file]); } catch { continue; }
      next[file] = st;
      if (!st.cwd || JUNK.test(st.cwd)) continue;
      out.push({ id: f.slice(0, -6), cwd: st.cwd, title: st.title || st.first || '', compacts: st.compacts, closed: st.closed, mtime: new Date(st.mtime).toISOString() });
    }
  }
  writeJson(CACHE, next);
  const live = liveSessions();
  for (const s of out) { s.live = !!live[s.id]; if (s.live) s.pid = live[s.id].pid; }
  out.sort((a, b) => b.mtime.localeCompare(a.mtime));
  return out;
}

function knownProjects() {
  const c = readJson(CACHE, {});
  const m = new Map();
  for (const st of Object.values(c)) if (st.cwd && !JUNK.test(st.cwd)) m.set(norm(st.cwd), st.cwd);
  return [...m.values()];
}

function resolveProject(q) {
  if (!q || /^(me|you|user)$/i.test(q)) return null;
  const all = knownProjects();
  const exact = all.filter(p => norm(p) === norm(q) || leaf(p).toLowerCase() === q.toLowerCase());
  if (exact.length) return exact[0];
  const part = all.filter(p => leaf(p).toLowerCase().includes(q.toLowerCase()));
  if (part.length === 1) return part[0];
  if (fs.existsSync(q)) return path.resolve(q).replace(/[\\/]+$/, '');
  throw new Error(`unknown project "${q}". Known: ${all.map(leaf).join(', ') || '(none yet - run "cc-remind scan" once, or pass a folder path)'}`);
}

function currentSession() {
  const sid = process.env.CLAUDE_CODE_SESSION_ID || null;
  let cwd = process.cwd();
  const pid = process.env.CLAUDE_PID;
  if (pid) { const j = readJson(path.join(LIVE_DIR, pid + '.json'), null); if (j && j.cwd) cwd = j.cwd; }
  let title = null;
  if (sid) {
    let dirs = [];
    try { dirs = fs.readdirSync(PROJECTS); } catch {}
    for (const d of dirs) {
      const file = path.join(PROJECTS, d, sid + '.jsonl');
      if (fs.existsSync(file)) { try { title = scanFile(file, readJson(CACHE, {})[file]).title; } catch {} break; }
    }
  }
  return { sessionId: sid, cwd, title };
}

function parseDue(s) {
  if (!s || s === true) return null;
  const now = new Date();
  const bad = () => new Error(`bad due "${s}" (use "YYYY-MM-DD HH:mm", +2h, +3d, tomorrow9; times are in ${TZ})`);
  const rel = s.match(/^\+(\d+)\s*([mhd])$/i);
  if (rel) {
    const n = +rel[1]; const u = rel[2].toLowerCase();
    return new Date(now.getTime() + n * (u === 'm' ? 60e3 : u === 'h' ? 3600e3 : 86400e3)).toISOString();
  }
  const tm = s.match(/^tomorrow(\d{1,2})?$/i);
  if (tm) {
    const h = tm[1] ? +tm[1] : 9; if (h > 23) throw bad();
    const p = zparts(now.getTime()); const t = new Date(Date.UTC(p.y, p.mo - 1, p.d + 1));
    return new Date(zoned(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate(), h, 0)).toISOString();
  }
  const m = s.trim().match(/^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?$/);
  if (m) {
    const [y, mo, d, h, mi] = [+m[1], +m[2], +m[3], m[4] ? +m[4] : 0, m[5] ? +m[5] : 0];
    const chk = new Date(Date.UTC(y, mo - 1, d, h, mi));
    if (chk.getUTCFullYear() !== y || chk.getUTCMonth() !== mo - 1 || chk.getUTCDate() !== d || chk.getUTCHours() !== h || chk.getUTCMinutes() !== mi) throw bad();
    return new Date(zoned(y, mo, d, h, mi)).toISOString();
  }
  if (/(Z|[+-]\d{2}:?\d{2})$/i.test(s.trim())) { const d = new Date(s.trim()); if (!isNaN(d)) return d.toISOString(); }
  throw bad();
}

function args(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { o._.push(...argv.slice(i + 1)); break; }
    if (a.startsWith('--')) { const k = a.slice(2); const v = argv[i + 1] !== undefined && !argv[i + 1].startsWith('--') ? argv[++i] : true; o[k] = v; }
    else o._.push(a);
  }
  return o;
}

const newId = db => { let id; do { id = crypto.randomBytes(2).toString('hex'); } while (db.items.some(x => x.id === id)); return id; };
const srcOf = x => x.from ? (x.from.cwd ? leaf(x.from.cwd) : x.from.label || '') + (x.from.title ? ' / ' + x.from.title : '') : '';
const fmt = x => `[${x.id}] (${x.pr}) ${x.to ? '-> ' + leaf(x.to) : 'you'}${x.due ? ' due ' + fmtTime(x.due) : ''} :: ${x.title}  <from ${srcOf(x)}, ${x.createdAt.slice(0, 10)}>`;

function findItem(db, id) { const x = db.items.find(i => i.id === id); if (!x) throw new Error(`no item ${id}`); return x; }

const USAGE = `cc-remind ${VERSION} - a reminder inbox shared by every Claude Code session

  cc-remind add "<one task>" [--to me|<project>] [--due "YYYY-MM-DD HH:mm"|+2h|+3d|tomorrow9] [--pr hi|mid|lo] [--note "..."] [--ref "..."]
  cc-remind done <id> "<what was done>"          close an item (records which session closed it)
  cc-remind done <id> --dropped "<why>"          close as no longer needed
  cc-remind done <id> --by-user                  close as done by you (not by a session)
  cc-remind list [--all] [--notes]               open items for this folder (or all)
  cc-remind show <id> [<id>...]
  cc-remind snooze <id> "<due>"
  cc-remind edit <id> [--title ...] [--due ...|none] [--pr ...] [--note ...] [--to ...]
  cc-remind reopen <id>
  cc-remind confirm <id>                         mark a stale item as still valid
  cc-remind scan [--out file.json]               scan sessions (used by the widget)
  cc-remind hook-start                           SessionStart hook (reads hook JSON on stdin)
  cc-remind paths                                print data dir, config and time zone as JSON

Times are read and shown in ${TZ}. Data: ${DATA}`;

const cmds = {
  scan(o) {
    const sessions = scanSessions();
    const db = readJson(TODOS, { items: [] });
    const live = new Set(sessions.filter(s => s.live).map(s => s.id));
    const titles = Object.fromEntries(sessions.map(s => [s.id, s.title]));
    const now = Date.now();
    const cutoff = now - 30 * 86400e3;
    const items = db.items.filter(x => !x.doneAt || Date.parse(x.doneAt) > cutoff).map(x => ({
      ...x,
      fromTitle: (x.from && x.from.sessionId && titles[x.from.sessionId]) || (x.from && x.from.title) || null,
      stale: !x.doneAt && now - Date.parse(x.confirmedAt || x.createdAt) > STALE_DAYS * 86400e3,
      orphan: !x.doneAt && !!x.to && !!x.from && !!x.from.sessionId && !!x.from.cwd && norm(x.to) === norm(x.from.cwd) && !live.has(x.from.sessionId),
    }));
    const notify = [];
    for (const x of db.items) {
      if (!x.doneAt && x.due && !x.notifiedAt && Date.parse(x.due) <= now)
        notify.push({ key: 'due:' + x.id, head: MSG.due + x.title, body: MSG.from + srcOf(x), sessionId: x.from && x.from.sessionId, cwd: x.from && x.from.cwd });
      if (x.doneAt && x.doneBy && x.doneBy.sessionId && !x.announcedAt)
        notify.push({ key: 'done:' + x.id, head: MSG.closed + x.title, body: MSG.by + leaf(x.doneBy.cwd) + (x.doneBy.title ? ' / ' + x.doneBy.title : '') + (x.doneNote ? ' - ' + x.doneNote : ''), sessionId: x.doneBy.sessionId, cwd: x.doneBy.cwd });
    }
    const projectRoots = Array.isArray(CFG.projectRoots) ? CFG.projectRoots.filter(r => r && typeof r.path === 'string').map(r => ({ label: String(r.label || leaf(r.path)), path: r.path })) : [];
    const json = JSON.stringify({ at: new Date().toISOString(), timeZone: TZ, language: LANG, projectRoots, sessions, items, notify });
    if (typeof o.out === 'string') { const t = o.out + '.tmp'; fs.writeFileSync(t, json); fs.renameSync(t, o.out); }
    else process.stdout.write(json);
  },

  add(o) {
    const title = o._.join(' ').trim();
    if (!title) throw new Error('usage: cc-remind add "<one task>" [--to me|<project>] [--due "YYYY-MM-DD HH:mm"|+2h|tomorrow9] [--pr hi|mid|lo] [--note "..."]');
    const pr = o.pr === undefined ? 'mid' : o.pr;
    if (!['hi', 'mid', 'lo'].includes(pr)) throw new Error('--pr must be hi, mid or lo');
    const to = resolveProject(o.to === true ? null : o.to);
    const due = parseDue(o.due);
    const from = currentSession();
    const x = withLock(db => {
      const x = { id: newId(db), title, note: typeof o.note === 'string' ? o.note : null, ref: typeof o.ref === 'string' ? o.ref : null, pr, to, due, from, createdAt: new Date().toISOString(), doneAt: null };
      db.items.push(x); return x;
    });
    console.log('added ' + fmt(x));
  },

  done(o) {
    const [id, ...rest] = o._;
    if (!id) throw new Error('usage: cc-remind done <id> "<what was done>"');
    const me = o['by-user'] ? null : currentSession();
    const x = withLock(db => {
      const x = findItem(db, id);
      if (x.doneAt) throw new Error(`${id} already done`);
      x.doneAt = new Date().toISOString(); x.doneBy = me; x.doneNote = rest.join(' ') || (typeof o.dropped === 'string' ? o.dropped : null); x.dropped = !!o.dropped;
      return x;
    });
    console.log('done ' + fmt(x));
  },

  reopen(o) { const x = withLock(db => { const x = findItem(db, o._[0]); x.doneAt = null; x.doneBy = null; x.doneNote = null; x.announcedAt = null; x.dropped = false; return x; }); console.log('reopened ' + fmt(x)); },

  snooze(o) { const due = parseDue(o._[1]); const x = withLock(db => { const x = findItem(db, o._[0]); x.due = due; x.notifiedAt = null; return x; }); console.log('snoozed ' + fmt(x)); },

  edit(o) {
    const x = withLock(db => {
      const x = findItem(db, o._[0]);
      if (typeof o.title === 'string') x.title = o.title;
      if (typeof o.note === 'string') x.note = o.note;
      if (typeof o.pr === 'string') { if (!['hi', 'mid', 'lo'].includes(o.pr)) throw new Error('--pr must be hi, mid or lo'); x.pr = o.pr; }
      if (typeof o.due === 'string') { x.due = o.due === 'none' ? null : parseDue(o.due); x.notifiedAt = null; }
      if (typeof o.to === 'string') x.to = resolveProject(o.to);
      return x;
    });
    console.log('edited ' + fmt(x));
  },

  confirm(o) { withLock(db => { findItem(db, o._[0]).confirmedAt = new Date().toISOString(); }); console.log('confirmed ' + o._[0]); },

  notified(o) {
    withLock(db => {
      for (const key of o._) {
        const [k, id] = key.split(':'); const x = db.items.find(i => i.id === id); if (!x) continue;
        x[k === 'due' ? 'notifiedAt' : 'announcedAt'] = new Date().toISOString();
      }
    });
  },

  list(o) {
    const db = readJson(TODOS, { items: [] });
    const here = norm(currentSession().cwd);
    let xs = db.items.filter(x => !x.doneAt);
    if (!o.all) xs = xs.filter(x => norm(x.to) === here || (x.from && norm(x.from.cwd) === here));
    if (!xs.length) return console.log(o.all ? 'no open items' : 'no open items for this project (use --all)');
    for (const x of xs) { console.log(fmt(x)); if (o.notes && x.note) console.log('      note: ' + x.note); }
  },

  show(o) {
    const db = readJson(TODOS, { items: [] });
    for (const id of o._) {
      const x = db.items.find(i => i.id === id);
      if (!x) { console.log(`no item ${id}`); continue; }
      console.log(fmt(x));
      for (const k of ['note', 'ref', 'due', 'doneAt', 'doneNote']) if (x[k]) console.log(`  ${k}: ${x[k]}`);
      if (x.to) console.log('  to: ' + x.to);
      if (x.from) console.log('  from: ' + (x.from.cwd || x.from.label) + (x.from.title ? ' / ' + x.from.title : ''));
    }
  },

  import(o) {
    const src = readJson(o._[0], null);
    if (!Array.isArray(src)) throw new Error('need a JSON array');
    const n = withLock(db => {
      for (const s of src) db.items.push({ id: newId(db), note: null, ref: null, pr: 'mid', due: null, doneAt: null, createdAt: new Date().toISOString(), ...s, to: s.to ? resolveProject(s.to) : null });
      return src.length;
    });
    console.log(`imported ${n}`);
  },

  paths() {
    console.log(JSON.stringify({ version: VERSION, data: DATA, configFile: CONFIG_FILE, todos: TODOS, claudeConfigDir: CLAUDE_DIR, timeZone: TZ, language: LANG, config: CFG }, null, 1));
  },

  'hook-start'() {
    let input = {};
    try { input = JSON.parse(fs.readFileSync(0, 'utf8') || '{}'); } catch {}
    const here = norm(input.cwd || process.cwd());
    const open = readJson(TODOS, { items: [] }).items.filter(x => !x.doneAt);
    const rank = { hi: 0, mid: 1, lo: 2 };
    const dueMs = x => (x.due ? new Date(x.due).getTime() : Infinity) || Infinity;
    const urgent = (a, b) => dueMs(a) - dueMs(b) || (rank[a.pr] ?? 1) - (rank[b.pr] ?? 1);
    const isToHere = x => !!x.to && under(here, norm(x.to));
    const isMine = x => !x.to && !!x.from && !!x.from.cwd && norm(x.from.cwd) === here;
    const all = open.filter(x => isToHere(x) || isMine(x)).sort(urgent);
    if (!all.length) return;
    const now = Date.now();
    const overdue = x => dueMs(x) <= now;
    const shown = all.slice(0, HOOK_CAP), rest = all.slice(HOOK_CAP);
    const toHere = shown.filter(isToHere), mine = shown.filter(isMine);
    const nOver = all.filter(overdue).length;
    const line = x => '  ' + (overdue(x) ? 'OVERDUE ' : '') + fmt(x);
    const lines = [`[cc-remind] Open reminders for this project: ${all.length} open${nOver ? `, ${nOver} overdue` : ''} (times in ${TZ}):`];
    if (toHere.length) {
      lines.push('Addressed to this project - handle them when relevant, then close with `cc-remind done <id> "<what you did>"` and tell the user in one line:');
      toHere.forEach(x => lines.push(line(x)));
    }
    if (mine.length) {
      lines.push('The user\'s to-dos raised from this project - if the user says one is done, or you finish it, close it with `cc-remind done <id>`:');
      mine.forEach(x => lines.push(line(x)));
    }
    if (rest.length) {
      const ro = rest.filter(overdue).length;
      lines.push(`  ...and ${rest.length} more not shown${ro ? ` (${ro} of them overdue)` : ''} - the most urgent are shown above; run \`cc-remind list\` to see all before working through reminders.`);
    }
    console.log(lines.join('\n'));
  },
};

const argv = process.argv.slice(2);
const cmd = argv.shift();
try {
  if (cmd === '--version' || cmd === '-v') { console.log(VERSION); process.exit(0); }
  if (!cmds[cmd]) { console.log(USAGE); process.exit(cmd && cmd !== 'help' && cmd !== '--help' && cmd !== '-h' ? 1 : 0); }
  cmds[cmd](args(argv));
} catch (e) { console.error('cc-remind: ' + e.message); process.exit(1); }
