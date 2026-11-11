import config from './config.js';
import { createAuth } from './auth.js';
import { createPositionStore } from './positions.js';

const $ = (id) => document.getElementById(id);
const audio = $('audio');
const positions = createPositionStore();
const auth = createAuth({
  cognitoDomain: config.cognitoDomain,
  clientId: config.clientId,
  redirectUri: `${location.origin}/`,
});

const LAST_KEY = 'lwp:last';
const RATE_KEY = 'lwp:rate';
const SAVE_INTERVAL_MS = 5000;

let episodes = [];
let current = null; // 再生中のエピソード
let loading = false; // src 差し替え中は位置を保存しない
let lastSavedAt = 0;
let recoverCount = 0;
let wantPlaying = false; // ユーザーが再生中のつもりか（エラーによる停止では false にしない）

// ------------------------------------------------------------
// API
// ------------------------------------------------------------
class AuthRequired extends Error {}

async function api(path) {
  for (const forceRefresh of [false, true]) {
    const token = await auth.getAccessToken({ forceRefresh });
    if (!token) break;
    const res = await fetch(`${config.apiUrl}${path}`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (res.status === 401) continue;
    if (!res.ok) throw new Error(`API error: ${res.status}`);
    return res.json();
  }
  throw new AuthRequired();
}

const fetchEpisodeUrl = async (key) =>
  (await api(`/episodes/url?key=${encodeURIComponent(key)}`)).url;

// ------------------------------------------------------------
// 一覧
// ------------------------------------------------------------
function formatMeta(ep) {
  const parts = [ep.station, ep.date && `${ep.date} ${ep.time}`];
  const p = positions.get(ep.key);
  if (p && !positions.isDone(ep.key)) parts.push(`${formatTime(p.t)} / ${formatTime(p.d)}`);
  else if (p) parts.push(`${formatTime(p.d)}・聴了`);
  else parts.push(`${(ep.size / 1024 / 1024).toFixed(1)} MB`);
  return parts.filter(Boolean).join('　');
}

function formatTime(sec) {
  const s = Math.floor(sec);
  const h = Math.floor(s / 3600);
  const m = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
  return `${h}:${m}:${String(s % 60).padStart(2, '0')}`;
}

function render() {
  const q = $('search').value.trim().toLowerCase();
  const hideDone = $('hide-done').checked;
  const tpl = $('episode-tpl');
  const list = $('episodes');
  const shown = episodes.filter(
    (ep) =>
      (!q || `${ep.title} ${ep.station} ${ep.key}`.toLowerCase().includes(q)) &&
      !(hideDone && positions.isDone(ep.key)),
  );

  list.replaceChildren(
    ...shown.map((ep) => {
      const li = tpl.content.firstElementChild.cloneNode(true);
      const btn = li.querySelector('.episode');
      btn.dataset.key = ep.key;
      btn.querySelector('.title').textContent = ep.title;
      btn.querySelector('.meta').textContent = formatMeta(ep);
      btn.querySelector('progress').value = positions.progress(ep.key);
      btn.classList.toggle('done', positions.isDone(ep.key));
      btn.classList.toggle('playing', current?.key === ep.key);
      btn.addEventListener('click', () => play(ep));
      return li;
    }),
  );
  $('status').textContent = `${shown.length} / ${episodes.length} 件`;
}

function refreshItem(key) {
  const btn = [...document.querySelectorAll('.episode')].find((b) => b.dataset.key === key);
  const ep = episodes.find((e) => e.key === key);
  if (!btn || !ep) return;
  btn.querySelector('.meta').textContent = formatMeta(ep);
  btn.querySelector('progress').value = positions.progress(key);
  btn.classList.toggle('done', positions.isDone(key));
}

async function loadEpisodes() {
  $('status').textContent = '読み込み中…';
  episodes = (await api('/episodes')).episodes;
  positions.prune(episodes.map((e) => e.key));
  render();
}

// ------------------------------------------------------------
// 再生
// ------------------------------------------------------------
async function load(ep, { autoplay }) {
  audio.pause();
  wantPlaying = false;
  savePosition();
  current = ep;
  recoverCount = 0;
  localStorage.setItem(LAST_KEY, ep.key);

  $('player').hidden = false;
  $('now-title').textContent = ep.title;
  $('now-meta').textContent = [ep.station, ep.date && `${ep.date} ${ep.time}`]
    .filter(Boolean)
    .join('　');
  document.title = `${ep.title} - Lambdiko Player`;
  document.querySelectorAll('.episode').forEach((b) => {
    b.classList.toggle('playing', b.dataset.key === ep.key);
  });

  await setSource(() => fetchEpisodeUrl(ep.key), positions.resumeAt(ep.key));
  if (autoplay) await audio.play().catch(() => {});

  if ('mediaSession' in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: ep.title,
      artist: ep.station,
      album: ep.date,
    });
  }
}

// 署名付き URL を取得して src を差し替え、メタデータ取得後に指定位置へシークする
async function setSource(getUrl, startAt) {
  loading = true;
  try {
    const url = await getUrl();
    await new Promise((resolve, reject) => {
      const onMeta = () => {
        audio.removeEventListener('error', onError);
        if (startAt > 0) audio.currentTime = startAt;
        audio.playbackRate = Number($('rate').value);
        resolve();
      };
      const onError = () => {
        audio.removeEventListener('loadedmetadata', onMeta);
        reject(new Error(`再生できませんでした（MediaError ${audio.error?.code}）`));
      };
      audio.addEventListener('loadedmetadata', onMeta, { once: true });
      audio.addEventListener('error', onError, { once: true });
      audio.src = url;
    });
  } finally {
    loading = false;
  }
}

const play = (ep) => load(ep, { autoplay: true }).catch(handleError);

function savePosition() {
  if (!current || loading || !audio.duration) return;
  positions.set(current.key, audio.currentTime, audio.duration);
  lastSavedAt = Date.now();
  refreshItem(current.key);
}

// 署名付き URL の期限切れなどで読み込みに失敗したら、URL を取り直して同じ位置から再開する
async function recover() {
  if (!current || loading || recoverCount >= 2) return;
  recoverCount++;
  const ep = current;
  const at = audio.currentTime || positions.resumeAt(ep.key);
  const wasPlaying = wantPlaying;
  try {
    await setSource(() => fetchEpisodeUrl(ep.key), at);
    if (wasPlaying) await audio.play().catch(() => {});
  } catch (err) {
    handleError(err);
  }
}

function skip(sec) {
  if (!audio.duration) return;
  audio.currentTime = Math.min(Math.max(audio.currentTime + sec, 0), audio.duration);
}

// ------------------------------------------------------------
// 画面
// ------------------------------------------------------------
function showLogin(message) {
  $('main-view').hidden = true;
  $('player').hidden = true;
  $('logout').hidden = true;
  $('login-view').hidden = false;
  $('login-message').textContent = message ?? 'ログインしてください。';
}

function handleError(err) {
  if (err instanceof AuthRequired) {
    showLogin('セッションの有効期限が切れました。もう一度ログインしてください。');
    return;
  }
  console.error(err);
  $('status').textContent = `エラー: ${err.message}`;
}

function bindEvents() {
  $('login').addEventListener('click', () => auth.login());
  $('logout').addEventListener('click', () => auth.logout());
  $('search').addEventListener('input', render);
  $('hide-done').addEventListener('change', render);
  $('reload').addEventListener('click', () => loadEpisodes().catch(handleError));
  $('back').addEventListener('click', () => skip(-15));
  $('fwd').addEventListener('click', () => skip(30));

  $('rate').value = localStorage.getItem(RATE_KEY) || '1';
  $('rate').addEventListener('change', () => {
    audio.playbackRate = Number($('rate').value);
    localStorage.setItem(RATE_KEY, $('rate').value);
  });

  audio.addEventListener('timeupdate', () => {
    if (!audio.paused && Date.now() - lastSavedAt > SAVE_INTERVAL_MS) savePosition();
  });
  audio.addEventListener('play', () => (wantPlaying = true));
  audio.addEventListener('pause', () => {
    if (!audio.error && !loading) wantPlaying = false;
    savePosition();
  });
  audio.addEventListener('ended', () => {
    wantPlaying = false;
    savePosition();
  });
  audio.addEventListener('playing', () => (recoverCount = 0));
  audio.addEventListener('error', () => recover());
  addEventListener('pagehide', savePosition);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') savePosition();
  });

  if ('mediaSession' in navigator) {
    navigator.mediaSession.setActionHandler('seekbackward', () => skip(-15));
    navigator.mediaSession.setActionHandler('seekforward', () => skip(30));
  }
}

async function main() {
  bindEvents();
  try {
    await auth.handleCallback();
  } catch (err) {
    console.error(err);
    showLogin('ログインに失敗しました。もう一度お試しください。');
    return;
  }

  if (!(await auth.getAccessToken())) {
    // 未ログインならそのままログイン画面へ
    await auth.login();
    return;
  }

  $('login-view').hidden = true;
  $('main-view').hidden = false;
  $('logout').hidden = false;

  try {
    await loadEpisodes();
    const last = episodes.find((e) => e.key === localStorage.getItem(LAST_KEY));
    if (last) await load(last, { autoplay: false });
  } catch (err) {
    handleError(err);
  }
}

main();
