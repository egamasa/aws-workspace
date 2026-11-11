// Cognito マネージドログイン（OAuth 2.0 認可コード + PKCE）
// クライアントシークレットは持たない（パブリッククライアント）

const TOKENS_KEY = 'lwp:tokens';
const PKCE_KEY = 'lwp:pkce';

export function createAuth({ cognitoDomain, clientId, redirectUri }) {
  let refreshing = null;

  const load = () => JSON.parse(localStorage.getItem(TOKENS_KEY) || 'null');
  const save = (t) => localStorage.setItem(TOKENS_KEY, JSON.stringify(t));
  const clear = () => localStorage.removeItem(TOKENS_KEY);

  async function tokenRequest(params) {
    const res = await fetch(`${cognitoDomain}/oauth2/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: clientId, ...params }),
    });
    if (!res.ok) throw new Error(`token endpoint: ${res.status}`);
    const body = await res.json();
    return {
      accessToken: body.access_token,
      idToken: body.id_token,
      // リフレッシュ時は refresh_token が返らないため呼び出し側で引き継ぐ
      refreshToken: body.refresh_token ?? params.refresh_token,
      expiresAt: Date.now() + body.expires_in * 1000,
    };
  }

  async function login() {
    const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const state = base64url(crypto.getRandomValues(new Uint8Array(16)));
    const challenge = base64url(
      new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))),
    );
    sessionStorage.setItem(PKCE_KEY, JSON.stringify({ verifier, state }));
    const url = new URL(`${cognitoDomain}/oauth2/authorize`);
    url.search = new URLSearchParams({
      response_type: 'code',
      client_id: clientId,
      redirect_uri: redirectUri,
      scope: 'openid email',
      state,
      code_challenge: challenge,
      code_challenge_method: 'S256',
    });
    location.assign(url);
  }

  // ログイン後のリダイレクト（?code=...&state=...）を処理する
  async function handleCallback() {
    const params = new URLSearchParams(location.search);
    const code = params.get('code');
    const error = params.get('error');
    if (!code && !error) return;
    history.replaceState(null, '', location.pathname);
    if (error) throw new Error(`login failed: ${error}`);

    const pkce = JSON.parse(sessionStorage.getItem(PKCE_KEY) || 'null');
    sessionStorage.removeItem(PKCE_KEY);
    if (!pkce || pkce.state !== params.get('state')) throw new Error('state mismatch');

    save(
      await tokenRequest({
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri,
        code_verifier: pkce.verifier,
      }),
    );
  }

  async function refresh() {
    const t = load();
    if (!t?.refreshToken) return null;
    try {
      const next = await tokenRequest({
        grant_type: 'refresh_token',
        refresh_token: t.refreshToken,
      });
      save(next);
      return next;
    } catch {
      clear();
      return null;
    }
  }

  // 有効なアクセストークンを返す。期限が近ければ更新し、更新できなければ null
  async function getAccessToken({ forceRefresh = false } = {}) {
    const t = load();
    if (!t) return null;
    if (!forceRefresh && t.expiresAt - Date.now() > 60_000) return t.accessToken;
    refreshing ??= refresh().finally(() => (refreshing = null));
    return (await refreshing)?.accessToken ?? null;
  }

  async function logout() {
    const t = load();
    clear();
    if (t?.refreshToken) {
      // リフレッシュトークンを失効させる（失敗してもログアウトは続行）
      await fetch(`${cognitoDomain}/oauth2/revoke`, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ token: t.refreshToken, client_id: clientId }),
      }).catch(() => {});
    }
    const url = new URL(`${cognitoDomain}/logout`);
    url.search = new URLSearchParams({ client_id: clientId, logout_uri: redirectUri });
    location.assign(url);
  }

  return { login, logout, handleCallback, getAccessToken };
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}
