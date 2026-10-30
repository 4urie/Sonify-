import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import find_metadata as metadata


class MetadataTests(unittest.TestCase):
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
