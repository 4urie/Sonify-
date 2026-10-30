"""Find possible missing song metadata, then generate SQL from reviewed matches."""
import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import boto3
from import_r2 import supabase_config, quote

FIELDS = ['approve', 'id', 'audio_path', 'current_title', 'current_artist', 'suggested_title', 'suggested_artist', 'suggested_album', 'cover_url', 'musicbrainz_url', 'lookup_status', 'lookup_note']
_last_lookup = 0.0


def clean_title(value):
    value = re.sub(r'\.(mp3|m4a|flac|wav|ogg|aac)$', '', value.strip(), flags=re.I)
    value = value.replace('_', ' ')
    value = re.sub(r'\s*[\[(](?:official\s+)?(?:music\s+)?(?:video|audio|lyrics?|lyric video|visualizer)[^\])]*[\])]', '', value, flags=re.I)
    # Some filenames spell every letter separately: M a k e I t ...
    words = value.split()
    if len(words) > 4 and all(len(word) == 1 and word.isalpha() for word in words):
        value = re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', ''.join(words))
    return ' '.join(value.split())


def search_terms(title, artist):
    """Try Title - Artist, Artist - Title, then the intact title."""
    artist = artist.strip()
    known_artist = artist if artist.casefold() not in ('', 'unknown', 'unknown artist') else ''
    parts = re.split(r'\s+[-–—]\s+', title.strip())
    terms = []
    if len(parts) == 2:
        left, right = map(clean_title, parts)
        if not known_artist:
            terms.extend([(left, right), (right, left)])
        elif right.casefold() == known_artist.casefold():
            terms.append((left, known_artist))
        elif left.casefold() == known_artist.casefold():
            terms.append((right, known_artist))
    terms.append((clean_title(title), known_artist))
    return list(dict.fromkeys(terms))


def musicbrainz_search(title, artist):
    global _last_lookup
    escape = lambda value: re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r'\\\1', value)
    query = 'recording:"' + escape(title) + '"'
    if artist:
        query += ' AND artist:"' + escape(artist) + '"'
    request = Request('https://musicbrainz.org/ws/2/recording/?' + urlencode({'query': query, 'fmt': 'json', 'limit': 10}), headers={'User-Agent': 'SonifyMetadataHelper/1.1 (https://github.com/4urie/Sonify-)', 'Accept': 'application/json'})
    for attempt in range(3):
        time.sleep(max(0, 1.1 - (time.monotonic() - _last_lookup)))
        _last_lookup = time.monotonic()
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response).get('recordings', [])
        except HTTPError as exc:
            if exc.code not in (429, 502, 503, 504) or attempt == 2:
                raise
            time.sleep(2 ** (attempt + 1))


def release_rank(release):
    group = release.get('release-group', {})
    return (release.get('status') != 'Official',
            bool(group.get('secondary-types')),
            group.get('primary-type') not in ('Album', 'Single'),
            release.get('date') or '9999')


def find_cover(releases):
    """Return the first release with an available front image, not a guessed URL."""
    seen = set()
    for release in sorted(releases, key=release_rank):
        release_id = release.get('id', '')
        if not re.fullmatch(r'[0-9a-f-]{36}', release_id) or release_id in seen:
            continue
        seen.add(release_id)
        url = 'https://coverartarchive.org/release/' + release_id + '/front-250'
        request = Request(url, method='HEAD', headers={
            'User-Agent': 'SonifyMetadataHelper/1.1 (https://github.com/4urie/Sonify-)'})
        for attempt in range(3):
            try:
                with urlopen(request, timeout=30) as response:
                    if response.headers.get('Content-Type', '').lower().startswith('image/'):
                        return release, url
                break
            except HTTPError as exc:
                if exc.code == 404:
                    break
                if exc.code not in (429, 502, 503, 504) or attempt == 2:
                    raise
                time.sleep(2 ** (attempt + 1))
    return None, ''


def catalog(url, key):
    last = None
    while True:
        params = {'select': 'id,title,artist,album,audio_path,artwork_path', 'order': 'id.asc', 'limit': '500'}
        if last:
            params['id'] = 'gt.' + last
        req = Request(url.rstrip('/') + '/rest/v1/songs?' + urlencode(params), headers={'apikey': key, 'Authorization': 'Bearer ' + key})
        with urlopen(req, timeout=30) as response:
            rows = json.load(response)
        if not isinstance(rows, list):
            raise ValueError('Unexpected catalog response')
        if not rows:
            return
        yield from rows
        current = rows[-1]['id']
        if last and current <= last:
            raise ValueError('Catalog pagination did not advance')
        last = current


def find_match(title, artist):
    record = None
    for song_title, song_artist in search_terms(title, artist):
        variants = [song_title]
        without_feature = re.sub(r'\s*\((?:feat\.?|ft\.?)\s+[^)]*\)', '', song_title, flags=re.I).strip()
        if without_feature != song_title:
            variants.append(without_feature)
        for variant in variants:
            recordings = musicbrainz_search(variant, song_artist)
            if recordings:
                record = min(recordings, key=lambda r: (
                    r.get('title', '').casefold() != variant.casefold(),
                    bool(re.search(r'live|karaoke|cover', r.get('disambiguation', ''), re.I)),
                    -int(r.get('score', 0)),
                ))
                break
        if record:
            break
    if record is None:
        return None
    credits = ''.join((c.get('name') or c.get('artist', {}).get('name', '')) + c.get('joinphrase', '') for c in record.get('artist-credit', []) if isinstance(c, dict))
    releases = record.get('releases') or []
    release, cover = find_cover(releases)
    release = release or min(releases or [{}], key=release_rank)
    return record.get('title', ''), credits, release.get('title', ''), cover, 'https://musicbrainz.org/recording/' + record.get('id', '')


def fingerprint_match(client, bucket, song, api_key, fpcalc):
    with tempfile.TemporaryDirectory(prefix='sonify-fingerprint-') as directory:
        local = Path(directory) / ('audio' + Path(song['audio_path']).suffix)
        client.download_file(bucket, song['audio_path'], str(local))
        result = subprocess.run([fpcalc, '-json', str(local)], capture_output=True, text=True, check=True, timeout=180)
        fingerprint = json.loads(result.stdout)
    payload = urlencode({'client': api_key, 'duration': round(fingerprint['duration']),
                         'fingerprint': fingerprint['fingerprint'], 'meta': 'recordings releases'}).encode()
    req = Request('https://api.acoustid.org/v2/lookup', data=payload, headers={'User-Agent': 'SonifyMetadataHelper/1.0', 'Content-Type': 'application/x-www-form-urlencoded'})
    with urlopen(req, timeout=30) as response:
        result = json.load(response)
    if result.get('status') != 'ok':
        raise ValueError('AcoustID lookup failed')
    for match in result.get('results', []):
        for record in match.get('recordings', []):
            artist = ', '.join(a.get('name', '') for a in record.get('artists', []))
            release, cover = find_cover(record.get('releases') or [])
            release = release or (record.get('releasegroups') or record.get('releases') or [{}])[0]
            return record.get('title', ''), artist, release.get('title', ''), cover, 'https://musicbrainz.org/recording/' + record.get('id', '')
    return None


def review_csv(path):
    import tkinter as tk
    from tkinter import ttk
    with open(path, encoding='utf-8-sig', newline='') as f:
        rows = list(csv.DictReader(f))
    root = tk.Tk()
    root.title('Review Sonify matches')
    root.geometry('900x480')
    tree = ttk.Treeview(root, columns=('current', 'title', 'artist', 'album', 'status', 'approved'), show='headings')
    for name in ('current', 'title', 'artist', 'album', 'status', 'approved'):
        tree.heading(name, text=name.title())
        tree.column(name, width=160)
    for i, row in enumerate(rows):
        tree.insert('', 'end', iid=str(i), values=(row['current_title'], row['suggested_title'], row['suggested_artist'], row['suggested_album'], row.get('lookup_status', ''), row['approve']))
    tree.pack(fill='both', expand=True)
    def toggle():
        for item in tree.selection():
            row = rows[int(item)]
            if not row.get('suggested_title'):
                continue
            row['approve'] = '' if row['approve'].lower() == 'yes' else 'yes'
            tree.set(item, 'approved', row['approve'])
    def save():
        with open(path, 'w', encoding='utf-8-sig', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)
        root.destroy()
    ttk.Label(root, text='Select matches to approve. Verify the recording and cover links in the CSV before applying SQL.').pack(pady=6)
    bar = ttk.Frame(root)
    bar.pack(pady=6)
    ttk.Button(bar, text='Toggle approval', command=toggle).pack(side='left', padx=4)
    ttk.Button(bar, text='Save and close', command=save).pack(side='left', padx=4)
    root.mainloop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['find', 'fingerprint', 'review', 'sql'])
    parser.add_argument('--csv', default='metadata-review.csv')
    parser.add_argument('--output', default='metadata-update.sql')
    parser.add_argument('--config', default='config.json')
    parser.add_argument('--fpcalc', default='fpcalc', help='Path to the Chromaprint fpcalc program')
    parser.add_argument('--bucket', default='sonify-music')
    parser.add_argument('--limit', type=int, help='Check only this many songs (useful for testing)')
    args = parser.parse_args()
    if args.limit is not None and args.limit < 1:
        parser.error('--limit must be greater than zero')
    if args.action == 'review':
        review_csv(args.csv)
    elif args.action in ('find', 'fingerprint'):
        url, key = supabase_config(Path(args.config))
        rows = list(catalog(url, key))
        client = None
        if args.action == 'fingerprint':
            account = os.environ.get('R2_ACCOUNT_ID', '')
            api_key = os.environ.get('ACOUSTID_CLIENT_KEY', '')
            if not re.fullmatch(r'[0-9a-fA-F]{32}', account) or not api_key or not os.environ.get('AWS_ACCESS_KEY_ID') or not os.environ.get('AWS_SECRET_ACCESS_KEY'):
                parser.error('Fingerprinting requires ACOUSTID_CLIENT_KEY and R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.')
            client = boto3.client('s3', endpoint_url=f'https://{account}.r2.cloudflarestorage.com', region_name='auto')
        if Path(args.csv).exists():
            backup = str(args.csv) + f'.{time.time_ns()}.bak'
            shutil.copy2(args.csv, backup)
            print(f'Previous review saved to {backup}')
        checked = matched = errors = 0
        with open(args.csv, 'w', encoding='utf-8-sig', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=FIELDS)
            writer.writeheader()
            for song in rows:
                artist = song.get('artist') or ''
                if artist.strip().lower() not in ('', 'unknown artist') and song.get('artwork_path'):
                    continue
                if args.limit is not None and checked >= args.limit:
                    break
                title = song.get('title', '').strip()
                match = None
                status = 'needs_fingerprint'
                note = 'No usable title. Use fingerprint mode or enter the song title.'
                if args.action == 'fingerprint' or (title and not title.isdecimal()):
                    try:
                        match = fingerprint_match(client, args.bucket, song, api_key, args.fpcalc) if client else find_match(title, artist)
                        status = 'suggested' if match else 'no_match'
                        note = ('Review the recording and cover; front image availability was verified.' if match[3]
                                else 'Recording found, but no available front cover was found on its releases.') if match else 'No matching recording found in the provider database.'
                    except Exception as exc:
                        status = 'request_failed'
                        note = f'{type(exc).__name__}: {exc}'
                        errors += 1
                        print(f'Lookup failed for {title}: {exc}', file=sys.stderr)
                    time.sleep(1.1)
                suggested_title, suggested_artist, album, cover, link = match or ('', '', '', '', '')
                writer.writerow(dict(zip(FIELDS, ['', song['id'], song['audio_path'], title, artist, suggested_title, suggested_artist, album, cover, link, status, note])))
                f.flush()
                checked += 1
                matched += bool(match)
                print(f'{status}: {title}', flush=True)
        print(f'Checked {checked}: {matched} suggestions, {errors} request failures. Review {args.csv}; approve only correct matches.')
    else:
        lines = ['-- Review before running in Supabase. Only missing artist and artwork are changed.', 'begin;']
        count = 0
        with open(args.csv, encoding='utf-8-sig', newline='') as f:
            for row in csv.DictReader(f):
                if row.get('approve', '').strip().lower() != 'yes':
                    continue
                song_id = row.get('id', '')
                if not re.fullmatch(r'[0-9a-fA-F-]{36}', song_id):
                    raise ValueError('Invalid song id in approved row')
                artist = row.get('suggested_artist', '').strip()
                title = row.get('suggested_title', '').strip()
                original = row.get('current_title', '').strip()
                if title and original == Path(row.get('audio_path', '')).stem:
                    lines.append(f"update public.songs set title = {quote(title)} where id = {quote(song_id)} and title = {quote(original)};")
                cover = row.get('cover_url', '').strip()
                if artist:
                    lines.append(f"update public.songs set artist = {quote(artist)} where id = {quote(song_id)} and (artist is null or btrim(artist) = '' or lower(btrim(artist)) = 'unknown artist');")
                if cover:
                    if not re.fullmatch(r'https://coverartarchive\.org/release/[0-9a-f-]{36}/front-250', cover):
                        raise ValueError('Invalid Cover Art Archive URL in approved row')
                    lines.append(f"update public.songs set artwork_path = {quote(cover)} where id = {quote(song_id)} and (artwork_path is null or btrim(artwork_path) = '');")
                count += 1
        lines.append('commit;')
        Path(args.output).write_text('\n'.join(lines) + '\n', encoding='utf-8')
        print(f'Wrote {count} approved matches to {args.output}. Review and run it in Supabase.')


if __name__ == '__main__':
    main()
