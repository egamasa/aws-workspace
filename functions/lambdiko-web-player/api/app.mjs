// Lambdiko Web Player API
// 認証は HTTP API の JWT オーソライザー（Cognito）で済んでいる前提
//   GET /episodes            録音ファイル一覧
//   GET /episodes/url?key=   再生用の署名付き URL

import { S3Client, ListObjectsV2Command, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { CONTENT_TYPES, extensionOf, isAudioKey, toEpisodes } from './lib/episodes.mjs';

const BUCKET = process.env.BUCKET_NAME;
const EXPIRES_IN = Number(process.env.URL_EXPIRES_IN || 10800);
const MAX_KEY_BYTES = 1024;

let s3 = new S3Client({});

// テスト用
export function setS3Client(client) {
  s3 = client;
}

function json(statusCode, body) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
    body: JSON.stringify(body),
  };
}

async function listAllObjects() {
  const objects = [];
  let token;
  do {
    const res = await s3.send(
      new ListObjectsV2Command({ Bucket: BUCKET, ContinuationToken: token }),
    );
    objects.push(...(res.Contents ?? []));
    token = res.IsTruncated ? res.NextContinuationToken : undefined;
  } while (token);
  return objects;
}

async function listEpisodes() {
  return json(200, { episodes: toEpisodes(await listAllObjects()) });
}

async function episodeUrl(event) {
  const key = event.queryStringParameters?.key;
  if (!key || Buffer.byteLength(key) > MAX_KEY_BYTES || !isAudioKey(key)) {
    return json(400, { message: 'invalid key' });
  }
  const command = new GetObjectCommand({
    Bucket: BUCKET,
    Key: key,
    // Lambdiko は Content-Type を付けずに保存しているため、応答時に上書きする（iOS Safari 対策）
    ResponseContentType: CONTENT_TYPES[extensionOf(key)],
  });
  const url = await getSignedUrl(s3, command, { expiresIn: EXPIRES_IN });
  const expiresAt = new Date(Date.now() + EXPIRES_IN * 1000).toISOString();
  return json(200, { url, expiresAt });
}

export async function handler(event) {
  try {
    switch (event.routeKey) {
      case 'GET /episodes':
        return await listEpisodes();
      case 'GET /episodes/url':
        return await episodeUrl(event);
      default:
        return json(404, { message: 'not found' });
    }
  } catch (err) {
    console.error(err);
    return json(500, { message: 'internal error' });
  }
}
