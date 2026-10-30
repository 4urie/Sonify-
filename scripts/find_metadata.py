"""Find possible missing song metadata, then generate SQL from reviewed matches."""
import argparse
import csv
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from import_r2 import supabase_config, quote

FIELDS = ['approve', 'id', 'audio_path', 'current_title', 'current_artist', 'suggested_title', 'suggested_artist', 'suggested_album', 'cover_url', 'musicbrainz_url']


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
    escaped = re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r'\\\1', title)
    query = 'recording:"' + escaped + '"'
    if artist and artist.lower() != 'unknown artist':
        query += ' AND artist:"' + re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r'\\\1', artist) + '"'
    req = Request('https://musicbrainz.org/ws/2/recording/?' + urlencode({'query': query, 'fmt': 'json', 'limit': 1}), headers={'User-Agent': 'SonifyMetadataHelper/1.0 (local music catalog tool)', 'Accept': 'application/json'})
    with urlopen(req, timeout=30) as response:
        recordings = json.load(response).get('recordings', [])
    if not recordings:
        return None
    record = recordings[0]
    credits = ''.join((c.get('name') or c.get('artist', {}).get('name', '')) + c.get('joinphrase', '') for c in record.get('artist-credit', []) if isinstance(c, dict))
    release = (record.get('releases') or [{}])[0]
    release_id = release.get('id', '')
    cover = 'https://coverartarchive.org/release/' + release_id + '/front-250' if re.fullmatch(r'[0-9a-f-]{36}', release_id) else ''
    return record.get('title', ''), credits, release.get('title', ''), cover, 'https://musicbrainz.org/recording/' + record.get('id', '')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['find', 'sql'])
    parser.add_argument('--csv', default='metadata-review.csv')
    parser.add_argument('--output', default='metadata-update.sql')
    parser.add_argument('--config', default='config.json')
    args = parser.parse_args()
    if args.action == 'find':
        url, key = supabase_config(Path(args.config))
        rows = list(catalog(url, key))
        with open(args.csv, 'w', encoding='utf-8-sig', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=FIELDS)
            writer.writeheader()
            for song in rows:
                artist = song.get('artist') or ''
                if artist.strip().lower() not in ('', 'unknown artist') and song.get('artwork_path'):
                    continue
                title = song.get('title', '').strip()
                match = None
                if title and not title.isdecimal():
                    try:
                        match = find_match(title, artist)
                    except Exception as exc:
                        print(f'Lookup failed for {title}: {exc}', file=sys.stderr)
                    time.sleep(1.1)
                suggested_title, suggested_artist, album, cover, link = match or ('', '', '', '', '')
                writer.writerow(dict(zip(FIELDS, ['', song['id'], song['audio_path'], title, artist, suggested_title, suggested_artist, album, cover, link])))
                print(f'Checked: {title}')
        print(f'Review {args.csv}; set approve to yes only for correct matches.')
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
