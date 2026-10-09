import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'cc.mjs');

function sandbox(extraEnv = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-remind-test-'));
  const data = path.join(root, 'data');
  const claude = path.join(root, 'claude');
  const proj = path.join(root, 'proj');
  fs.mkdirSync(path.join(claude, 'projects'), { recursive: true });
  fs.mkdirSync(proj);
  const env = { ...process.env, CC_REMIND_DATA: data, CLAUDE_CONFIG_DIR: claude, CC_REMIND_TZ: 'UTC', ...extraEnv };
  for (const k of Object.keys(env)) if (k === 'CLAUDECODE' || k.startsWith('CLAUDE_CODE_') || k === 'CLAUDE_PID') delete env[k];
  const run = (args, opts = {}) => {
    const r = spawnSync(process.execPath, [CLI, ...args], { env: { ...env, ...(opts.env || {}) }, cwd: opts.cwd || proj, input: opts.input, encoding: 'utf8' });
    return { code: r.status, out: r.stdout, err: r.stderr };
  };
  const db = () => JSON.parse(fs.readFileSync(path.join(data, 'todos.json'), 'utf8'));
  const writeDb = items => { fs.mkdirSync(data, { recursive: true }); fs.writeFileSync(path.join(data, 'todos.json'), JSON.stringify({ items })); };
  return { root, data, proj, run, db, writeDb, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

test('add, list, done round trip', () => {
  const s = sandbox();
  try {
    let r = s.run(['add', 'first task', '--pr', 'hi']);
    assert.equal(r.code, 0, r.err);
    const id = s.db().items[0].id;
    assert.match(r.out, /added \[[0-9a-f]{4}\] \(hi\) you :: first task/);
    r = s.run(['list']);
    assert.match(r.out, /first task/);
    r = s.run(['done', id, 'did it']);
    assert.equal(r.code, 0, r.err);
    const x = s.db().items[0];
    assert.ok(x.doneAt);
    assert.equal(x.doneNote, 'did it');
    assert.match(s.run(['list']).out, /no open items/);
  } finally { s.cleanup(); }
});

test('--due is read in the configured time zone and shown in it', () => {
  const s = sandbox({ CC_REMIND_TZ: 'America/New_York' });
  try {
    assert.equal(s.run(['add', 'ny', '--due', '2026-10-12 10:00']).code, 0);
    assert.equal(s.db().items[0].due, '2026-10-12T14:00:00.000Z');
    assert.match(s.run(['list']).out, /due 2026-10-12 10:00/);
    assert.match(s.run(['list'], { env: { CC_REMIND_TZ: 'Asia/Tokyo' } }).out, /due 2026-10-12 23:00/);
  } finally { s.cleanup(); }
});

test('config.json timeZone is used when no env var is set', () => {
  const s = sandbox({ CC_REMIND_TZ: '' });
  try {
    fs.mkdirSync(s.data, { recursive: true });
    fs.writeFileSync(path.join(s.data, 'config.json'), JSON.stringify({ timeZone: 'Asia/Kolkata' }));
    assert.equal(s.run(['add', 'in', '--due', '2026-01-05 09:30']).code, 0);
    assert.equal(s.db().items[0].due, '2026-01-05T04:00:00.000Z');
  } finally { s.cleanup(); }
});

test('due handles DST and rejects impossible dates', () => {
  const s = sandbox({ CC_REMIND_TZ: 'Europe/Berlin' });
  try {
    assert.equal(s.run(['add', 'summer', '--due', '2026-07-01 12:00']).code, 0);
    assert.equal(s.run(['add', 'winter', '--due', '2026-12-01 12:00']).code, 0);
    const [a, b] = s.db().items;
    assert.equal(a.due, '2026-07-01T10:00:00.000Z');
    assert.equal(b.due, '2026-12-01T11:00:00.000Z');
    const r = s.run(['add', 'bad', '--due', '2026-02-30 10:00']);
    assert.equal(r.code, 1);
    assert.match(r.err, /bad due/);
  } finally { s.cleanup(); }
});

test('hook-start shows overdue items first, caps at 8 and counts the rest', () => {
  const s = sandbox();
  try {
    const now = Date.now(), day = 86400e3;
    const items = [];
    for (let i = 0; i < 9; i++) items.push({ id: 'a' + i, title: 'project task ' + i, pr: 'mid', to: s.proj, due: new Date(now + (i + 2) * day).toISOString(), from: { cwd: path.join(s.root, 'other') }, createdAt: '2026-01-01T00:00:00Z', doneAt: null });
    for (let i = 0; i < 3; i++) items.push({ id: 'b' + i, title: 'late user task ' + i, pr: 'lo', to: null, due: new Date(now - (i + 1) * day).toISOString(), from: { cwd: s.proj }, createdAt: '2026-01-01T00:00:00Z', doneAt: null });
    items.push({ id: 'c0', title: 'elsewhere', pr: 'hi', to: path.join(s.root, 'other'), due: null, from: null, createdAt: '2026-01-01T00:00:00Z', doneAt: null });
    s.writeDb(items);
    const r = s.run(['hook-start'], { input: JSON.stringify({ cwd: s.proj }) });
    assert.equal(r.code, 0, r.err);
    const shown = r.out.split('\n').filter(l => /^\s+(OVERDUE )?\[/.test(l));
    assert.equal(shown.length, 8);
    for (const id of ['b0', 'b1', 'b2']) assert.match(r.out, new RegExp(`OVERDUE \\[${id}\\]`));
    assert.doesNotMatch(r.out, /elsewhere/);
    assert.match(r.out, /12 open, 3 overdue/);
    assert.match(r.out, /\.\.\.and 4 more not shown/);
  } finally { s.cleanup(); }
});

test('hook-start reaches subfolders and is silent when nothing is open', () => {
  const s = sandbox();
  try {
    const sub = path.join(s.proj, 'pkg');
    fs.mkdirSync(sub);
    s.writeDb([{ id: 'd0', title: 'for the parent project', pr: 'mid', to: s.proj, due: null, from: null, createdAt: '2026-01-01T00:00:00Z', doneAt: null }]);
    assert.match(s.run(['hook-start'], { input: JSON.stringify({ cwd: sub }) }).out, /for the parent project/);
    assert.equal(s.run(['hook-start'], { input: JSON.stringify({ cwd: s.root }) }).out, '');
  } finally { s.cleanup(); }
});

test('--to resolves a folder path and the item shows up there', () => {
  const s = sandbox();
  try {
    const other = path.join(s.root, 'other-app');
    fs.mkdirSync(other);
    assert.equal(s.run(['add', 'tell other-app', '--to', other]).code, 0);
    assert.match(s.run(['list'], { cwd: other }).out, /-> other-app :: tell other-app/);
    const r = s.run(['add', 'x', '--to', 'no-such-project']);
    assert.equal(r.code, 1);
    assert.match(r.err, /unknown project/);
  } finally { s.cleanup(); }
});
