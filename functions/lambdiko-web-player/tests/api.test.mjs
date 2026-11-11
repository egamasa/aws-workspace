import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

process.env.BUCKET_NAME = 'example-bucket';
process.env.URL_EXPIRES_IN = '3600';
process.env.AWS_REGION = 'ap-northeast-1';
process.env.AWS_ACCESS_KEY_ID = 'AKIDEXAMPLE';
process.env.AWS_SECRET_ACCESS_KEY = 'secret';

const { parseKey, toEpisodes, isAudioKey } = await import('../api/lib/episodes.mjs');
const { handler, setS3Client } = await import('../api/app.mjs');
// api/ の node_modules から読み込む
const { S3Client } = createRequire(new URL('../api/package.json', import.meta.url))(
  '@aws-sdk/client-s3',
);

test('parseKey: Lambdiko 形式（タイトルに _ を含む、29 時間制）', () => {
  assert.deepEqual(parseKey('安部_礼司_FMT_202611082530.m4a'), {
    title: '安部_礼司',
    station: 'FMT',
    date: '2026-11-08',
    time: '25:30',
    airtime: '202611082530',
  });
});

test('parseKey: 形式外のキーはファイル名をタイトルにする', () => {
  assert.equal(parseKey('misc/hello.m4a').title, 'hello');
  assert.equal(parseKey('misc/hello.m4a').airtime, '');
});

test('isAudioKey', () => {
  assert.ok(isAudioKey('a.m4a'));
  assert.ok(isAudioKey('a.MP3'));
  assert.ok(!isAudioKey('a.txt'));
  assert.ok(!isAudioKey('dir/'));
});

test('toEpisodes: 音声以外を除外し、放送日時の新しい順に並べる', () => {
  const eps = toEpisodes([
    { Key: 'A_TBS_202611010900.m4a', Size: 1 },
    { Key: 'note.txt', Size: 1 },
    { Key: 'B_QRR_202611022500.m4a', Size: 2 },
    { Key: 'C_NHK_202611021000.m4a', Size: 3 },
  ]);
  assert.deepEqual(
    eps.map((e) => e.key),
    ['B_QRR_202611022500.m4a', 'C_NHK_202611021000.m4a', 'A_TBS_202611010900.m4a'],
  );
});

function fakeS3(pages) {
  const client = new S3Client({ region: 'ap-northeast-1' });
  const calls = [];
  client.send = async (cmd) => {
    calls.push(cmd.input);
    return pages[calls.length - 1];
  };
  return { client, calls };
}

test('GET /episodes: ページングして全件返す', async () => {
  const { client, calls } = fakeS3([
    {
      Contents: [{ Key: 'A_TBS_202611010900.m4a', Size: 1 }],
      IsTruncated: true,
      NextContinuationToken: 't1',
    },
    { Contents: [{ Key: 'B_TBS_202611020900.m4a', Size: 1 }], IsTruncated: false },
  ]);
  setS3Client(client);
  const res = await handler({ routeKey: 'GET /episodes' });
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).episodes.length, 2);
  assert.equal(calls[1].ContinuationToken, 't1');
  assert.equal(calls[0].Bucket, 'example-bucket');
});

test('GET /episodes/url: 署名付き URL に Content-Type 上書きと有効期限が付く', async () => {
  setS3Client(new S3Client({ region: 'ap-northeast-1' }));
  const key = 'あ、安部礼司_FMT_202611081700.m4a';
  const res = await handler({ routeKey: 'GET /episodes/url', queryStringParameters: { key } });
  assert.equal(res.statusCode, 200);
  const url = new URL(JSON.parse(res.body).url);
  assert.equal(url.host, 'example-bucket.s3.ap-northeast-1.amazonaws.com');
  assert.equal(decodeURIComponent(url.pathname.slice(1)), key);
  assert.equal(url.searchParams.get('response-content-type'), 'audio/mp4');
  assert.equal(url.searchParams.get('X-Amz-Expires'), '3600');
});

test('GET /episodes/url: 不正なキーは 400', async () => {
  for (const q of [undefined, {}, { key: 'secret.txt' }, { key: 'x'.repeat(1100) + '.m4a' }]) {
    const res = await handler({ routeKey: 'GET /episodes/url', queryStringParameters: q });
    assert.equal(res.statusCode, 400);
  }
});

test('未定義のルートは 404、例外は 500', async () => {
  assert.equal((await handler({ routeKey: 'POST /x' })).statusCode, 404);
  setS3Client({
    send: async () => {
      throw new Error('boom');
    },
  });
  const orig = console.error;
  console.error = () => {};
  assert.equal((await handler({ routeKey: 'GET /episodes' })).statusCode, 500);
  console.error = orig;
});
