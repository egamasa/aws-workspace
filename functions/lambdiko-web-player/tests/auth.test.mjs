import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

// auth.js はブラウザのグローバル（localStorage, fetch）を呼び出し時に参照するため、差し替えて検証する
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => store.set(k, String(v)),
  removeItem: (k) => store.delete(k),
};

const { createAuth } = await import('../web/auth.js');

const TOKENS_KEY = 'lwp:tokens';
const auth = createAuth({
  cognitoDomain: 'https://example.auth.ap-northeast-1.amazoncognito.com',
  clientId: 'client',
  redirectUri: 'https://example.cloudfront.net/',
});

function saveTokens(expiresInMs) {
  store.set(
    TOKENS_KEY,
    JSON.stringify({
      accessToken: 'old-access',
      idToken: 'old-id',
      refreshToken: 'refresh',
      expiresAt: Date.now() + expiresInMs,
    }),
  );
}

function stubFetch(handler) {
  globalThis.fetch = async (url, init) => handler(url, init);
}

const tokenResponse = (body) => ({ ok: true, status: 200, json: async () => body });
const errorResponse = (status) => ({ ok: false, status, json: async () => ({}) });

beforeEach(() => store.clear());

test('getAccessToken: 期限に余裕があれば更新しない', async () => {
  saveTokens(10 * 60_000);
  stubFetch(() => assert.fail('fetch は呼ばれないはず'));
  assert.equal(await auth.getAccessToken(), 'old-access');
});

test('getAccessToken: 期限が近ければ更新し、リフレッシュトークンを引き継ぐ', async () => {
  saveTokens(30_000);
  stubFetch(() => tokenResponse({ access_token: 'new-access', id_token: 'new-id', expires_in: 3600 }));
  assert.equal(await auth.getAccessToken(), 'new-access');
  assert.equal(JSON.parse(store.get(TOKENS_KEY)).refreshToken, 'refresh');
});

test('getAccessToken: リフレッシュトークンが無効（400）ならセッションを破棄して null', async () => {
  saveTokens(-1000);
  stubFetch(() => errorResponse(400));
  assert.equal(await auth.getAccessToken(), null);
  assert.equal(store.has(TOKENS_KEY), false);
});

test('getAccessToken: 通信エラーではトークンを残し、期限切れなら例外を投げる', async () => {
  saveTokens(-1000);
  stubFetch(() => {
    throw new TypeError('Failed to fetch');
  });
  await assert.rejects(auth.getAccessToken(), TypeError);
  assert.ok(store.has(TOKENS_KEY));
});

test('getAccessToken: 5xx でもトークンを残す', async () => {
  saveTokens(-1000);
  stubFetch(() => errorResponse(503));
  await assert.rejects(auth.getAccessToken());
  assert.ok(store.has(TOKENS_KEY));
});

test('getAccessToken: 更新が一時的に失敗しても、アクセストークンが有効ならそれを返す', async () => {
  saveTokens(30_000);
  stubFetch(() => {
    throw new TypeError('Failed to fetch');
  });
  assert.equal(await auth.getAccessToken(), 'old-access');
  assert.ok(store.has(TOKENS_KEY));
});

test('getAccessToken: forceRefresh（401 後）は一時的な失敗でも古いトークンを返さない', async () => {
  saveTokens(30_000);
  stubFetch(() => {
    throw new TypeError('Failed to fetch');
  });
  await assert.rejects(auth.getAccessToken({ forceRefresh: true }), TypeError);
  assert.ok(store.has(TOKENS_KEY));
});

test('getAccessToken: 未ログインなら null', async () => {
  assert.equal(await auth.getAccessToken(), null);
});
