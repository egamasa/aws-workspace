// 録音ファイルのキー解析
// Lambdiko の保存形式: {タイトル}_{局ID}_{YYYYMMDDHHMM}.m4a
// radiko は 29 時間制のため、時は 00〜28 を取りうる

export const CONTENT_TYPES = {
  m4a: 'audio/mp4',
  mp4: 'audio/mp4',
  aac: 'audio/aac',
  mp3: 'audio/mpeg',
};

const KEY_PATTERN = /^(?:.*\/)?(.+)_([^_/]+)_(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})\.([a-z0-9]+)$/i;

export function extensionOf(key) {
  const m = /\.([a-z0-9]+)$/i.exec(key);
  return m ? m[1].toLowerCase() : '';
}

export function isAudioKey(key) {
  return Object.hasOwn(CONTENT_TYPES, extensionOf(key));
}

export function parseKey(key) {
  const m = KEY_PATTERN.exec(key);
  if (!m) {
    const name = key.split('/').pop().replace(/\.[^.]+$/, '');
    return { title: name, station: '', date: '', time: '', airtime: '' };
  }
  const [, title, station, y, mo, d, hh, mm] = m;
  return {
    title,
    station,
    date: `${y}-${mo}-${d}`,
    time: `${hh}:${mm}`,
    // 並べ替え用（29 時間制でも文字列比較で放送順になる）
    airtime: `${y}${mo}${d}${hh}${mm}`,
  };
}

export function toEpisodes(objects) {
  return objects
    .filter((o) => o.Key && isAudioKey(o.Key))
    .map((o) => ({
      key: o.Key,
      size: o.Size ?? 0,
      lastModified: o.LastModified ? new Date(o.LastModified).toISOString() : null,
      ...parseKey(o.Key),
    }))
    .sort(
      (a, b) =>
        (b.airtime || '').localeCompare(a.airtime || '') ||
        (b.lastModified || '').localeCompare(a.lastModified || '') ||
        a.key.localeCompare(b.key),
    );
}
