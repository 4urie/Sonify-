import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_r2


class Response(io.BytesIO):
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.close()


class ImportTests(unittest.TestCase):
    def test_catalog_reads_multiple_pages_until_empty(self):
        pages = [
            [{'id': '001', 'audio_path': 'old.mp3'}],
            [{'id': '002', 'audio_path': 'folder/new.mp3'}],
            [],
        ]
        calls = []
        def open_page(request, timeout):
            calls.append(request.full_url)
            return Response(json.dumps(pages.pop(0)).encode())
        with patch.object(import_r2, 'urlopen', side_effect=open_page):
            self.assertEqual(import_r2.existing_audio_paths('https://example.supabase.co', 'key'), {'old.mp3', 'folder/new.mp3'})
        self.assertIn('id=gt.001', calls[1])
        self.assertIn('id=gt.002', calls[2])

    def test_existing_objects_are_not_downloaded(self):
        client = MagicMock()
        client.get_paginator.return_value.paginate.return_value = [{'Contents': [{'Key': 'old.mp3'}, {'Key': 'new.mp3'}]}]
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'R2_ACCOUNT_ID': 'a' * 32, 'AWS_ACCESS_KEY_ID': 'key', 'AWS_SECRET_ACCESS_KEY': 'secret'}), patch.object(import_r2, 'supabase_config', return_value=('https://example.supabase.co', 'key')), patch.object(import_r2, 'existing_audio_paths', return_value={'old.mp3'}), patch.object(import_r2.boto3, 'client', return_value=client), patch.object(import_r2, 'audio_file', return_value=None), patch.object(sys, 'argv', ['import_r2.py', '--output', str(Path(directory) / 'out.sql')]):
            import_r2.main()
            client.download_file.assert_called_once()
            self.assertEqual(client.download_file.call_args.args[1], 'new.mp3')
            sql = (Path(directory) / 'out.sql').read_text(encoding='utf-8')
            self.assertIn('new.mp3', sql)
            self.assertNotIn('old.mp3', sql)


if __name__ == '__main__':
    unittest.main()
