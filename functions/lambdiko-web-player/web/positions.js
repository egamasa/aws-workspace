// 再生位置の保存（localStorage）
// キーごとに { t: 再生位置秒, d: 長さ秒, at: 更新時刻 } を保存する

const PREFIX = 'lwp:pos:';
// 残りがこの秒数未満なら「聴き終えた」とみなす
const DONE_MARGIN = 30;
// 一覧から消えたキーの位置情報を残す期間
const RETENTION_MS = 180 * 24 * 60 * 60 * 1000;

export function createPositionStore(storage = localStorage) {
  function get(key) {
    try {
      return JSON.parse(storage.getItem(PREFIX + key) || 'null');
    } catch {
      return null;
    }
  }

  function set(key, t, d) {
    if (!Number.isFinite(t) || !Number.isFinite(d) || d <= 0) return;
    storage.setItem(PREFIX + key, JSON.stringify({ t, d, at: Date.now() }));
  }

  function isDone(p) {
    return !!p && p.d - p.t < DONE_MARGIN;
  }

  // 0〜1 の進捗
  function progress(key) {
    const p = get(key);
    if (!p) return 0;
    return isDone(p) ? 1 : Math.min(p.t / p.d, 1);
  }

  // 続きから再生する位置（聴き終えていれば先頭から）
  function resumeAt(key) {
    const p = get(key);
    return !p || isDone(p) ? 0 : Math.max(p.t - 3, 0);
  }

  // S3 から消えたファイルの位置情報を古いものから掃除する
  function prune(existingKeys, now = Date.now()) {
    const keep = new Set(existingKeys);
    for (let i = storage.length - 1; i >= 0; i--) {
      const k = storage.key(i);
      if (!k?.startsWith(PREFIX) || keep.has(k.slice(PREFIX.length))) continue;
      const p = get(k.slice(PREFIX.length));
      if (!p || now - p.at > RETENTION_MS) storage.removeItem(k);
    }
  }

  return { get, set, isDone: (key) => isDone(get(key)), progress, resumeAt, prune };
}
