"""Sync new R2 audio objects into Supabase. Intended for a trusted server."""
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path, PurePosixPath
from urllib.request import Request, urlopen

import boto3
from mutagen import File as audio_file
from import_r2 import EXTENSIONS, embedded_cover, existing_audio_paths, first


def required(name):
    value = os.environ.get(name, '').strip()
    if not value:
        raise ValueError(f'Missing required environment variable: {name}')
    return value


def insert_song(url, secret, song):
    headers = {'apikey': secret, 'Content-Type': 'application/json', 'User-Agent': 'SonifySync/1.0'}
    if not secret.startswith('sb_secret_'):
        headers['Authorization'] = 'Bearer ' + secret
    req = Request(url.rstrip('/') + '/rest/v1/rpc/sync_insert_song',
                  data=json.dumps(song).encode(), method='POST',
                  headers=headers)
    with urlopen(req, timeout=30) as response:
        return json.load(response)


def sync(client, bucket, url, secret):
    existing = existing_audio_paths(url, secret)
    inserted = skipped = failed = 0
    pages = client.get_paginator('list_objects_v2').paginate(Bucket=bucket)
    for page in pages:
        for obj in page.get('Contents', []):
            key = obj['Key']
            suffix = PurePosixPath(key).suffix.lower()
            if suffix not in EXTENSIONS or key in existing:
                continue
            try:
                with tempfile.TemporaryDirectory(prefix='sonify-sync-') as directory:
                    local = Path(directory) / ('audio' + suffix)
                    client.download_file(bucket, key, str(local))
                    audio = audio_file(local, easy=True)
                    tags = audio.tags if audio else None
                    title = first(tags, 'title', PurePosixPath(key).stem)
                    artist = first(tags, 'artist', 'Unknown Artist')
                    album = first(tags, 'album', '')
                    length = getattr(getattr(audio, 'info', None), 'length', 0)
                    duration = round(length * 1000) if length and length > 0 else None
                    cover = embedded_cover(local)
                    artwork = None
                    if cover:
                        data, mime = cover
                        ext = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp'}[mime]
                        cover_key = f'sonify-artwork/{hashlib.sha256(data).hexdigest()}.{ext}'
                        client.put_object(Bucket=bucket, Key=cover_key, Body=data, ContentType=mime)
                        artwork = 'r2:' + cover_key
                    created = insert_song(url, secret, {'p_title': title, 'p_artist': artist,
                        'p_album': album, 'p_audio_path': key, 'p_artwork_path': artwork,
                        'p_duration_ms': duration})
                existing.add(key)
                if created:
                    inserted += 1
                    print(f'Added: {key}')
                else:
                    skipped += 1
            except Exception as exc:
                failed += 1
                print(f'Could not sync {key}: {type(exc).__name__}', file=sys.stderr)
    print(f'Sync finished: {inserted} added, {skipped} already added concurrently, {failed} failed.')
    if failed:
        print('Some songs failed; they will be retried next run.', file=sys.stderr)


def main():
    account = required('R2_ACCOUNT_ID')
    if not re.fullmatch(r'[0-9a-fA-F]{32}', account):
        raise ValueError('R2_ACCOUNT_ID must be a 32-character account ID')
    required('AWS_ACCESS_KEY_ID')
    required('AWS_SECRET_ACCESS_KEY')
    url = required('SUPABASE_URL')
    if not re.fullmatch(r'https://[a-zA-Z0-9-]+\.supabase\.co/?', url):
        raise ValueError('SUPABASE_URL must be your HTTPS Supabase project URL')
    secret = required('SUPABASE_SECRET_KEY')
    bucket = os.environ.get('R2_BUCKET', 'sonify-music')
    client = boto3.client('s3', endpoint_url=f'https://{account}.r2.cloudflarestorage.com', region_name='auto')
    sync(client, bucket, url, secret)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'Sync failed: {type(exc).__name__}: {exc}', file=sys.stderr)
        sys.exit(1)
