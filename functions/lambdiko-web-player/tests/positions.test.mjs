import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createPositionStore } from '../web/positions.js';

function memoryStorage() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    key: (i) => [...m.keys()][i] ?? null,
    get length() {
      return m.size;
    },
  };
}

test('位置の保存・進捗・再開位置', () => {
  const s = createPositionStore(memoryStorage());
  assert.equal(s.progress('a'), 0);
  assert.equal(s.resumeAt('a'), 0);
  s.set('a', 600, 3600);
  assert.equal(s.progress('a'), 600 / 3600);
  assert.equal(s.resumeAt('a'), 597);
  assert.equal(s.isDone('a'), false);
});

test('残り 30 秒未満は聴了扱いで先頭から再生', () => {
  const s = createPositionStore(memoryStorage());
  s.set('a', 3580, 3600);
  assert.equal(s.isDone('a'), true);
  assert.equal(s.progress('a'), 1);
  assert.equal(s.resumeAt('a'), 0);
});

test('不正な値は保存しない', () => {
  const s = createPositionStore(memoryStorage());
  s.set('a', NaN, 100);
  s.set('b', 10, 0);
  s.set('c', 10, Infinity);
  assert.equal(s.get('a'), null);
  assert.equal(s.get('b'), null);
  assert.equal(s.get('c'), null);
});

test('prune: 一覧に無く保持期間を過ぎたものだけ消す', () => {
  const storage = memoryStorage();
  const s = createPositionStore(storage);
  s.set('old', 1, 100);
  s.set('recent', 1, 100);
  s.set('kept', 1, 100);
  storage.setItem('other', 'x');
  const old = JSON.parse(storage.getItem('lwp:pos:old'));
  storage.setItem('lwp:pos:old', JSON.stringify({ ...old, at: 0 }));
  s.prune(['kept']);
  assert.equal(s.get('old'), null);
  assert.ok(s.get('recent'));
  assert.ok(s.get('kept'));
  assert.equal(storage.getItem('other'), 'x');
});
