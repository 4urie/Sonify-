import io
import json
import unittest
from unittest.mock import patch, MagicMock
from urllib.error import HTTPError

import find_metadata as metadata


class MetadataTests(unittest.TestCase):
    def test_cover_tries_next_release_after_missing_image(self):
        releases = [{'id': 'a' * 36, 'title': 'No artwork'},
                    {'id': 'b' * 36, 'title': 'With artwork'}]
        response = MagicMock()
        response.__enter__.return_value.headers = {'Content-Type': 'image/jpeg'}
        missing = HTTPError('https://coverartarchive.org', 404, 'Not found', {}, None)
        with patch.object(metadata, 'urlopen', side_effect=[missing, response]):
            release, cover = metadata.find_cover(releases)
        self.assertEqual(release['title'], 'With artwork')
        self.assertIn('b' * 36, cover)

    def test_missing_cover_does_not_invent_url(self):
        missing = HTTPError('https://coverartarchive.org', 404, 'Not found', {}, None)
        with patch.object(metadata, 'urlopen', side_effect=missing):
            self.assertEqual(metadata.find_cover([{'id': 'a' * 36}]), (None, ''))

    def test_cover_network_failure_is_reported(self):
        error = HTTPError('https://coverartarchive.org', 503, 'Unavailable', {}, None)
        with patch.object(metadata, 'urlopen', side_effect=error) as request, patch.object(metadata.time, 'sleep'):
            with self.assertRaises(HTTPError):
                metadata.find_cover([{'id': 'a' * 36}])
        self.assertEqual(request.call_count, 3)

    def test_html_response_is_not_a_cover(self):
        response = MagicMock()
        response.__enter__.return_value.headers = {'Content-Type': 'text/html'}
        with patch.object(metadata, 'urlopen', return_value=response):
            self.assertEqual(metadata.find_cover([{'id': 'a' * 36}]), (None, ''))

    def test_filename_splits_only_spaced_separator(self):
        self.assertEqual(metadata.search_terms('Pa-umaga - Al James', 'Unknown Artist')[0], ('Pa-umaga', 'Al James'))
        self.assertEqual(metadata.search_terms('Thuggish Ruggish Bone - Bone Thugs-N-Harmony', '')[0], ('Thuggish Ruggish Bone', 'Bone Thugs-N-Harmony'))

    def test_letter_spacing_and_known_artist(self):
        self.assertEqual(metadata.clean_title('M a k e I t T o T h e M o r n i n g'), 'Make It To The Morning')
        self.assertEqual(metadata.search_terms('Arctic Monkeys - Secret Door.mp3', 'Arctic Monkeys')[0], ('Secret Door', 'Arctic Monkeys'))

    def test_tries_reverse_filename_order(self):
        record = {'id': 'recording', 'title': 'Secret Door', 'artist-credit': [{'name': 'Arctic Monkeys'}]}
        with patch.object(metadata, 'musicbrainz_search', side_effect=[[], [record]]) as search:
            result = metadata.find_match('Arctic Monkeys - Secret Door', 'Unknown Artist')
        self.assertEqual(search.call_args_list[1].args, ('Secret Door', 'Arctic Monkeys'))
        self.assertEqual(result[:2], ('Secret Door', 'Arctic Monkeys'))

    def test_request_failure_is_not_treated_as_no_match(self):
        with patch.object(metadata, 'musicbrainz_search', side_effect=HTTPError('https://musicbrainz.org', 503, 'Unavailable', {}, None)):
            with self.assertRaises(HTTPError):
                metadata.find_match('Song', 'Artist')

    def test_retry_rate_limit_then_success(self):
        response = io.BytesIO(json.dumps({'recordings': [{'title': 'Song'}]}).encode())
        error = HTTPError('https://musicbrainz.org', 429, 'Too many requests', {}, None)
        with patch.object(metadata, 'urlopen', side_effect=[error, response]) as request, patch.object(metadata.time, 'sleep'):
            self.assertEqual(metadata.musicbrainz_search('Song', 'Artist'), [{'title': 'Song'}])
        self.assertEqual(request.call_count, 2)


if __name__ == '__main__':
    unittest.main()
