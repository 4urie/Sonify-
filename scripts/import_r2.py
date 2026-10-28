#!/usr/bin/env python3
"""Generate a reviewable Supabase SQL import from objects in an R2 bucket."""
import argparse
import base64
import hashlib
import os
import re
import sys
import tempfile
from pathlib import Path, PurePosixPath

import boto3
from mutagen import File as audio_file
from mutagen.flac import Picture

EXTENSIONS = {'.mp3', '.m4a', '.aac', '.ogg', '.flac', '.wav'}


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def first(tags, key, fallback):
    value = tags.get(key) if tags else None
    return str(value[0]).strip() if value and str(value[0]).strip() else fallback


def embedded_cover(path):
    """Return the first supported embedded cover as (bytes, MIME type)."""
    audio = audio_file(path)
    if not audio:
        return None
    pictures = list(getattr(audio, 'pictures', []))
    tags = audio.tags or {}
    if hasattr(tags, 'getall'):
        pictures.extend(tags.getall('APIC'))
    for encoded in tags.get('metadata_block_picture', []):
        try:
            pictures.append(Picture(base64.b64decode(encoded)))
        except (ValueError, TypeError):
            continue
    for picture in pictures:
        if getattr(picture, 'mime', '') in ('image/jpeg', 'image/png', 'image/webp'):
            return picture.data, picture.mime
    for cover in tags.get('covr', []):
        data = bytes(cover)
        if data.startswith(b'\xff\xd8\xff'):
            return data, 'image/jpeg'
        if data.startswith(b'\x89PNG\r\n\x1a\n'):
            return data, 'image/png'
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bucket', default='sonify-music')
    parser.add_argument('--prefix', default='', help='Only import keys starting with this prefix')
    parser.add_argument('--output', default='r2-songs-import.sql')
    parser.add_argument('--upload-covers', action='store_true', help='Extract covers and upload them to the R2 bucket (requires object write access)')
    args = parser.parse_args()
    account = os.environ.get('R2_ACCOUNT_ID')
    if not account or not os.environ.get('AWS_ACCESS_KEY_ID') or not os.environ.get('AWS_SECRET_ACCESS_KEY'):
        parser.error('Set R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables first.')
    if not re.fullmatch(r'[0-9a-fA-F]{32}', account):
        parser.error('R2_ACCOUNT_ID must be the 32-character hexadecimal Account ID from the Cloudflare dashboard, without extra characters or a URL.')
    client = boto3.client('s3', endpoint_url=f'https://{account}.r2.cloudflarestorage.com', region_name='auto')
    rows = []
    paginator = client.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=args.bucket, Prefix=args.prefix):
        for obj in page.get('Contents', []):
            key = obj['Key']
            suffix = PurePosixPath(key).suffix.lower()
            if suffix not in EXTENSIONS:
                continue
            with tempfile.TemporaryDirectory(prefix='sonify-import-') as directory:
                local = Path(directory) / ('audio' + suffix)
                client.download_file(args.bucket, key, str(local))
                try:
                    audio = audio_file(local, easy=True)
                    tags = audio.tags if audio else None
                    title = first(tags, 'title', PurePosixPath(key).stem)
                    artist = first(tags, 'artist', 'Unknown Artist')
                    album = first(tags, 'album', '')
                    length = getattr(getattr(audio, 'info', None), 'length', 0)
                    duration = round(length * 1000) if length and length > 0 else None
                except Exception as exc:
                    print(f'Could not read metadata for {key}: {exc}; using filename.', file=sys.stderr)
                    title, artist, album, duration = PurePosixPath(key).stem, 'Unknown Artist', '', None
                artwork = None
                if args.upload_covers:
                    try:
                        cover = embedded_cover(local)
                    except Exception as exc:
                        print(f'Could not read cover for {key}: {exc}', file=sys.stderr)
                        cover = None
                    if cover:
                        data, mime = cover
                        extension = {'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp'}[mime]
                        cover_key = f'sonify-artwork/{hashlib.sha256(data).hexdigest()}.{extension}'
                        client.put_object(Bucket=args.bucket, Key=cover_key, Body=data, ContentType=mime)
                        artwork = 'r2:' + cover_key
            rows.append((title, artist, album, key, duration, artwork))
            print(f'Prepared: {key}')
    lines = ['-- Review this file before running it in the Supabase SQL Editor.',
             '-- Existing metadata and artwork are preserved; missing artwork can be filled.', 'begin;']
    for title, artist, album, key, duration, artwork in rows:
        values = ', '.join([quote(title), quote(artist), quote(album), quote(key), str(duration) if duration else 'null', quote(artwork) if artwork else 'null'])
        lines.append('insert into public.songs (title, artist, album, audio_path, duration_ms, artwork_path)\n'
                     f'select {values}\nwhere not exists (select 1 from public.songs where audio_path = {quote(key)});')
        if artwork:
            lines.append(f'update public.songs set artwork_path = {quote(artwork)} where audio_path = {quote(key)} and artwork_path is null;')
    lines.append('commit;')
    Path(args.output).write_text('\n\n'.join(lines) + '\n', encoding='utf-8')
    print(f'Wrote {len(rows)} songs to {args.output}. Review it before running it in Supabase.')


if __name__ == '__main__':
    main()
