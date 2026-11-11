import config from './config.js';
import { createAuth } from './auth.js';
import { createPositionStore } from './positions.js';

const $ = (id) => document.getElementById(id);
// <audio> を 2 つ交互に使う。audio が再生中（画面に表示する方）、standby は次の番組の先読み用
let audio = $('audio');
let standby = $('audio-standby');
const positions = createPositionStore();
const auth = createAuth({
  cognitoDomain: config.cognitoDomain,
  clientId: config.clientId,
  redirectUri: `${location.origin}/`,
});

const LAST_KEY = 'lwp:last';
const RATE_KEY = 'lwp:rate';
const ORDER_KEY = 'lwp:order';
const SAVE_INTERVAL_MS = 5000;
// 残りがこの秒数を切ったら、次の番組を standby に先読みする
const PRELOAD_BEFORE_END_SEC = 120;
// 先読みした番組を使う期間（署名付き URL の有効期限より十分短くする）
const PRELOAD_MAX_AGE_MS = 60 * 60 * 1000;
// 先読みに失敗したときに、やり直すまでの間隔
const PRELOAD_RETRY_MS = 30 * 1000;
// 番組の読み込みに失敗したときに、やり直すまでの待ち時間
const LOAD_RETRY_DELAYS_MS = [1000, 3000, 10000];

let episodes = [];
let current = null; // 再生中のエピソード
let loading = false; // src 差し替え中は位置を保存しない
let lastSavedAt = 0;
let recoverCount = 0;
let wantPlaying = false; // ユーザーが再生中のつもりか（エラーによる停止では false にしない）
let loadSeq = 0; // load() の世代。新しい番組を選ぶたびに進め、古い読み込みの結果を捨てるのに使う
let preloaded = null; // standby に先読みした番組 { key, at, failed }
let preloading = false;

// 新しい load() に追い越された古い読み込み。エラーとしては扱わない
class Superseded extends Error {}

// audio の読み込みの失敗。原因を調べられるよう、ブラウザが出す詳細（error.message）も表示する
class MediaLoadError extends Error {
  constructor(mediaError) {
    const detail = [mediaError?.code, mediaError?.message].filter(Boolean).join(': ');
    super(`再生できませんでした（MediaError ${detail}${document.hidden ? '、バックグラウンド' : ''}）`);
  }
}

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

// 並び順を反映した全件（API は放送日時の新しい順で返す）
const sortedEpisodes = () => ($('order').value === 'asc' ? [...episodes].reverse() : episodes);

// 並び順・検索・聴了の非表示を反映した、画面に表示する一覧
function visibleEpisodes() {
  const q = $('search').value.trim().toLowerCase();
  const hideDone = $('hide-done').checked;
  return sortedEpisodes().filter(
    (ep) =>
      (!q || `${ep.title} ${ep.station} ${ep.key}`.toLowerCase().includes(q)) &&
      !(hideDone && positions.isDone(ep.key)),
  );
}

function render() {
  const tpl = $('episode-tpl');
  const list = $('episodes');
  const shown = visibleEpisodes();

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
  loadSeq++;
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
  document.querySelectorAll('.episode').forEach((b) => {
    b.classList.toggle('playing', b.dataset.key === ep.key);
  });
  if ('mediaSession' in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: ep.title,
      artist: ep.station,
      album: ep.date,
    });
  }

  const seq = loadSeq;
  const startAt = positions.resumeAt(ep.key);

  // 次の番組を standby に先読みしてあれば、通信を待たずに切り替えて再生する。
  // Android の Chrome は画面オフで音が止まると通信できなくなるため、
  // 番組が終わってから読み込みを始めると失敗する
  if (takePreloaded(ep.key)) {
    try {
      await switchToStandby(startAt, { autoplay });
      return;
    } catch (err) {
      if (!(err instanceof MediaLoadError)) throw err;
      console.warn(err);
    }
  } else {
    clearStandby();
  }

  // 読み込みに失敗したら（通信の失敗、URL の期限切れなど）、URL を取り直して何度かやり直す
  for (let attempt = 0; ; attempt++) {
    try {
      await setSource(() => fetchEpisodeUrl(ep.key), startAt, { autoplay });
      return;
    } catch (err) {
      if (!(err instanceof MediaLoadError) || attempt >= LOAD_RETRY_DELAYS_MS.length) throw err;
      console.warn(err);
      await new Promise((r) => setTimeout(r, LOAD_RETRY_DELAYS_MS[attempt]));
      if (seq !== loadSeq) throw new Superseded();
    }
  }
}

// 署名付き URL を取得して src を差し替え、メタデータ取得後に指定位置へシークする
// 途中で別の番組が選ばれたら（loadSeq が進んだら）Superseded を投げて何も変更しない
async function setSource(getUrl, startAt, { autoplay = false } = {}) {
  const seq = loadSeq;
  loading = true;
  try {
    const url = await getUrl();
    if (seq !== loadSeq) throw new Superseded();
    audio.src = url;
    // メタデータを待たずに再生を始める（iOS はメタデータを先読みしないことがある）
    if (autoplay) audio.play().catch(() => {});
    await waitForMetadata(audio, seq, startAt);
  } finally {
    // 追い越された場合、loading は新しい読み込みが管理する
    if (seq === loadSeq) loading = false;
  }
}

// standby（先読みした番組）を再生側に切り替える
// 前の番組の要素を止めるのは、次の番組の play() を呼んでから（音の途切れる時間を作らないため）
async function switchToStandby(startAt, { autoplay }) {
  const seq = loadSeq;
  const prev = audio;
  [audio, standby] = [standby, audio];
  audio.hidden = false;
  prev.hidden = true;
  audio.playbackRate = Number($('rate').value);
  loading = true;
  try {
    if (autoplay) audio.play().catch(() => {});
    clearStandby();
    await waitForMetadata(audio, seq, startAt);
  } finally {
    if (seq === loadSeq) loading = false;
  }
}

// メタデータの読み込みを待ち、指定位置へシークする（読み込み済みならすぐに済ませる）
function waitForMetadata(el, seq, startAt) {
  return new Promise((resolve, reject) => {
    const finish = (fn) => {
      el.removeEventListener('loadedmetadata', onMeta);
      el.removeEventListener('error', onError);
      if (seq !== loadSeq) reject(new Superseded());
      else fn();
    };
    const onMeta = () =>
      finish(() => {
        if (startAt > 0 && Math.abs(el.currentTime - startAt) > 1) el.currentTime = startAt;
        el.playbackRate = Number($('rate').value);
        resolve();
      });
    const onError = () => finish(() => reject(new MediaLoadError(el.error)));
    el.addEventListener('loadedmetadata', onMeta);
    el.addEventListener('error', onError);
    if (el.error) onError();
    else if (el.readyState >= HTMLMediaElement.HAVE_METADATA) onMeta();
  });
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
    await setSource(() => fetchEpisodeUrl(ep.key), at, { autoplay: wasPlaying });
  } catch (err) {
    handleError(err);
  }
}

function skip(sec) {
  if (!audio.duration) return;
  audio.currentTime = Math.min(Math.max(audio.currentTime + sec, 0), audio.duration);
}

// 一覧の表示順で隣の番組へ移る（offset: 1 で一覧の下、-1 で上）。
// 再生中の番組が絞り込みで一覧から外れていても（聴き終えて非表示になった場合など）、
// 全件の並びでの位置から、一覧に表示されている隣の番組を探す。
function adjacentEpisode(offset) {
  if (!current) return null;
  const all = sortedEpisodes();
  const shown = new Set(visibleEpisodes().map((e) => e.key));
  for (let i = all.findIndex((e) => e.key === current.key) + offset; i >= 0 && i < all.length; i += offset) {
    if (shown.has(all[i].key)) return all[i];
  }
  return null;
}

function playAdjacent(offset) {
  const ep = adjacentEpisode(offset);
  if (ep) play(ep);
}

// 先読みした番組が使えるか（key が一致し、読み込みに失敗しておらず、古すぎない）
function takePreloaded(key) {
  const p = preloaded;
  preloaded = null;
  return p?.key === key && !p.failed && !standby.error && Date.now() - p.at < PRELOAD_MAX_AGE_MS;
}

function clearStandby() {
  preloaded = null;
  standby.pause();
  if (standby.hasAttribute('src')) {
    standby.removeAttribute('src');
    standby.load();
  }
}

// 再生中（音が出ていてバックグラウンドでも通信できるうち）に、次の番組を standby に読み込んでおく
async function preloadNext() {
  if (preloading || !audio.duration || audio.duration - audio.currentTime > PRELOAD_BEFORE_END_SEC) return;
  const next = adjacentEpisode(1);
  if (!next) return;
  if (preloaded?.key === next.key) {
    const age = Date.now() - preloaded.at;
    if (age < (preloaded.failed || standby.error ? PRELOAD_RETRY_MS : PRELOAD_MAX_AGE_MS)) return;
  }
  const seq = loadSeq;
  preloading = true;
  try {
    const url = await fetchEpisodeUrl(next.key);
    if (seq !== loadSeq) return;
    const el = standby;
    preloaded = { key: next.key, at: Date.now() };
    el.preload = 'auto';
    el.src = url;
    // 続きから再生する番組なら、その位置のデータを読み込ませる
    const at = positions.resumeAt(next.key);
    if (at > 0) {
      el.addEventListener(
        'loadedmetadata',
        () => {
          if (el === standby && preloaded?.key === next.key) el.currentTime = at;
        },
        { once: true },
      );
    }
  } catch (err) {
    // 失敗しても番組の切り替え時に読み込み直すので、ここでは記録だけする
    console.error(err);
    if (seq === loadSeq) preloaded = { key: next.key, at: Date.now(), failed: true };
  } finally {
    preloading = false;
  }
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
  if (err instanceof Superseded) return;
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
  $('order').value = localStorage.getItem(ORDER_KEY) === 'asc' ? 'asc' : 'desc';
  $('order').addEventListener('change', () => {
    localStorage.setItem(ORDER_KEY, $('order').value);
    render();
  });
  $('reload').addEventListener('click', () => loadEpisodes().catch(handleError));
  $('back').addEventListener('click', () => skip(-15));
  $('fwd').addEventListener('click', () => skip(30));

  $('rate').value = localStorage.getItem(RATE_KEY) || '1';
  $('rate').addEventListener('change', () => {
    audio.playbackRate = Number($('rate').value);
    localStorage.setItem(RATE_KEY, $('rate').value);
  });

  // 2 つの <audio> のうち、再生側（audio）のイベントだけを扱う
  for (const el of [audio, standby]) {
    const on = (type, fn) => el.addEventListener(type, (e) => e.target === audio && fn());
    on('timeupdate', () => {
      if (audio.paused || loading) return;
      if (Date.now() - lastSavedAt > SAVE_INTERVAL_MS) savePosition();
      preloadNext();
    });
    on('play', () => (wantPlaying = true));
    on('pause', () => {
      if (!audio.error && !loading) wantPlaying = false;
      savePosition();
    });
    on('ended', () => {
      wantPlaying = false;
      savePosition();
      playAdjacent(1);
    });
    on('playing', () => (recoverCount = 0));
    on('error', () => recover());
  }
  addEventListener('pagehide', savePosition);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') savePosition();
    // バックグラウンドで読み込みに失敗したまま止まっていたら、画面に戻ったときにやり直す
    else if (current && audio.error && wantPlaying && !loading) play(current);
  });

  if ('mediaSession' in navigator) {
    navigator.mediaSession.setActionHandler('seekbackward', () => skip(-15));
    navigator.mediaSession.setActionHandler('seekforward', () => skip(30));
    navigator.mediaSession.setActionHandler('previoustrack', () => playAdjacent(-1));
    navigator.mediaSession.setActionHandler('nexttrack', () => playAdjacent(1));
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

  let token;
  try {
    token = await auth.getAccessToken();
  } catch (err) {
    // トークンの更新が通信エラーなどで失敗した場合。セッションは残っているので再ログインはさせない
    console.error(err);
    showLogin('通信できませんでした。電波の良い場所でページを開き直してください。');
    return;
  }
  if (!token) {
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
