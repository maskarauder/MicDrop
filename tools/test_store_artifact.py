import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from store_artifact import KIND, collect_files, store


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.workspace = self.base / 'checkout'
        self.workspace.mkdir()
        self.root = self.base / 'artifacts'
        self.source = self.workspace / 'build' / 'app-debug.apk'
        self.source.parent.mkdir()
        self.source.write_bytes(b'build contents')

    def save(self, run='1', attempt='1', **kwargs):
        return store(self.workspace, self.root, 'android-apk', run, attempt,
                     'build/*.apk', **kwargs)

    def symlink(self, link, target):
        try:
            link.symlink_to(target, target_is_directory=target.is_dir())
        except (OSError, NotImplementedError):
            self.skipTest('This account cannot create symlinks')

    def test_copy_survives_checkout_removal_with_hash_and_identity(self):
        with patch.dict('os.environ', {'GITHUB_SHA': 'a' * 40, 'GITHUB_REF': 'refs/pull/39/merge'}):
            destination = self.save()
        self.source.unlink()
        self.assertEqual((destination / 'files/app-debug.apk').read_bytes(), b'build contents')
        metadata = json.loads((destination / 'manifest.json').read_text())
        self.assertEqual(metadata['kind'], KIND)
        self.assertEqual(metadata['sha'], 'a' * 40)
        self.assertEqual(metadata['files'][0]['sha256'], hashlib.sha256(b'build contents').hexdigest())
        self.assertFalse(list(destination.parent.glob('.pending-*')))

    def test_multiple_directories_keep_distinct_relative_names(self):
        for directory in ('one', 'two'):
            folder = self.workspace / directory
            folder.mkdir()
            (folder / 'result.txt').write_text(directory)
        destination = store(self.workspace, self.root, 'reports', '1', '1', 'one\ntwo')
        self.assertEqual((destination / 'files/one/result.txt').read_text(), 'one')
        self.assertEqual((destination / 'files/two/result.txt').read_text(), 'two')

    def test_attempts_are_separate_and_existing_evidence_is_not_overwritten(self):
        first = self.save()
        second = self.save(attempt='2')
        self.assertNotEqual(first, second)
        with self.assertRaises(FileExistsError):
            self.save()

    def test_missing_outputs_do_not_create_or_prune_storage(self):
        self.source.unlink()
        self.assertIsNone(self.save())
        self.assertFalse(self.root.exists())

    def test_source_cannot_escape_checkout(self):
        for pattern in ('../private', str(self.base / 'private')):
            with self.subTest(pattern=pattern), self.assertRaises(ValueError):
                collect_files(self.workspace, pattern)

    def test_source_symlink_cannot_copy_private_files(self):
        private = self.base / 'private'
        private.write_text('secret')
        self.source.unlink()
        self.symlink(self.source, private)
        with self.assertRaises(ValueError):
            self.save()

    def test_destination_symlink_is_rejected(self):
        private = self.base / 'private'
        private.mkdir()
        self.root.mkdir()
        self.symlink(self.root / 'android-apk', private)
        with self.assertRaises(ValueError):
            self.save()
        self.assertEqual(list(private.iterdir()), [])

    def test_retention_keeps_at_most_ten_copies(self):
        for run in range(1, 13):
            self.save(str(run), now=1_000_000 + run)
        remaining = {p.name for p in (self.root / 'android-apk').iterdir()}
        self.assertEqual(remaining, {f'{run}-1' for run in range(3, 13)})

    def test_expiry_only_removes_our_completed_copies(self):
        old = self.save('1', now=1_000_000)
        unrelated = old.parent / '2-1'
        unrelated.mkdir()
        (unrelated / 'manifest.json').write_text('{"kind":"user-data","created_unix":0}')
        (unrelated / 'keep.txt').write_text('keep')
        current = self.save('3', now=1_000_000 + 15 * 86400)
        self.assertFalse(old.exists())
        self.assertTrue(current.exists())
        self.assertTrue((unrelated / 'keep.txt').exists())

    def test_pruning_does_not_follow_directory_symlinks(self):
        first = self.save()
        private = self.base / 'private'
        private.mkdir()
        (private / 'manifest.json').write_text(json.dumps({'kind': KIND, 'created_unix': 0}))
        self.symlink(first.parent / '999-1', private)
        self.save('2')
        self.assertTrue((private / 'manifest.json').exists())

    def test_failed_copy_preserves_previous_evidence(self):
        first = self.save('1', now=1)
        with patch('store_artifact.shutil.copy2', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.save('2', now=3_000_000)
        self.assertTrue(first.exists())
        self.assertFalse((first.parent / '2-1').exists())
        self.assertFalse(list(first.parent.glob('.pending-*')))

    def test_invalid_names_and_retention_are_rejected(self):
        for name in ('../outside', '.', '..', '/absolute', 'x/y'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                store(self.workspace, self.root, name, '1', '1', 'build')
        for days in (0, -1, 91):
            with self.subTest(days=days), self.assertRaises(ValueError):
                self.save(days=days)

    def test_os_ancestor_symlink_is_allowed_while_root_symlink_is_rejected(self):
        real = self.base / 'private_var'
        real.mkdir()
        (real / 'checkout' / 'build').mkdir(parents=True)
        (real / 'checkout' / 'build' / 'app-debug.apk').write_bytes(b'build contents')
        alias = self.base / 'var'
        self.symlink(alias, real)
        destination = store(alias / 'checkout', alias / 'artifacts', 'android-apk', '1', '1', 'build/*.apk')
        self.assertEqual((destination / 'files/app-debug.apk').read_bytes(), b'build contents')
        outside = self.base / 'outside'
        outside.mkdir()
        self.symlink(real / 'linked-root', outside)
        with self.assertRaises(ValueError):
            store(alias / 'checkout', alias / 'linked-root', 'android-apk', '2', '1', 'build/*.apk')

    def test_main_summary_omits_runner_filesystem_paths(self):
        runner_root = self.base / 'runner'
        runner_temp = runner_root / 'temp'
        runner_temp.mkdir(parents=True)
        summary = self.base / 'summary.md'
        output = self.base / 'output.txt'
        env = {
            'MICDROP_ARTIFACT_NAME': 'android-apk',
            'MICDROP_ARTIFACT_PATHS': 'build/*.apk',
            'RUNNER_TEMP': str(runner_temp),
            'GITHUB_REPOSITORY_ID': '12345',
            'GITHUB_RUN_ID': '77',
            'GITHUB_RUN_ATTEMPT': '2',
            'GITHUB_WORKSPACE': str(self.workspace),
            'GITHUB_STEP_SUMMARY': str(summary),
            'GITHUB_OUTPUT': str(output),
        }
        from store_artifact import main as store_main
        with patch.dict('os.environ', env, clear=False):
            store_main()
        summary_text = summary.read_text(encoding='utf-8')
        self.assertIn('**android-apk** retained (`77-2`)', summary_text)
        self.assertNotIn(str(runner_root), summary_text)
        self.assertIn('has-files=true', output.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
