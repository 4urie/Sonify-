import unittest
from unittest.mock import MagicMock, patch
import sync_r2


class SyncTests(unittest.TestCase):
    def test_skips_existing_and_inserts_new(self):
        client = MagicMock()
        client.get_paginator.return_value.paginate.return_value = [{'Contents': [{'Key': 'old.mp3'}, {'Key': 'new.mp3'}, {'Key': 'cover.jpg'}]}]
        with patch.object(sync_r2, 'existing_audio_paths', return_value={'old.mp3'}), patch.object(sync_r2, 'audio_file', return_value=None), patch.object(sync_r2, 'embedded_cover', return_value=None), patch.object(sync_r2, 'insert_song', return_value=True) as insert:
            sync_r2.sync(client, 'bucket', 'https://example.supabase.co', 'secret')
        client.download_file.assert_called_once()
        self.assertEqual(client.download_file.call_args.args[1], 'new.mp3')
        self.assertEqual(insert.call_args.args[2]['p_title'], 'new')
        self.assertEqual(insert.call_args.args[2]['p_artist'], 'Unknown Artist')

    def test_failure_is_reported_without_failing_run(self):
        client = MagicMock()
        client.get_paginator.return_value.paginate.return_value = [{'Contents': [{'Key': 'new.mp3'}]}]
        client.download_file.side_effect = OSError('failed')
        with patch.object(sync_r2, 'existing_audio_paths', return_value=set()), patch('sys.stderr') as stderr:
            sync_r2.sync(client, 'bucket', 'https://example.supabase.co', 'secret')
            self.assertTrue(stderr.write.called)


if __name__ == '__main__':
    unittest.main()
