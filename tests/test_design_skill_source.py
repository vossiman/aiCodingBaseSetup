"""Behavior checks: failed source refresh must never replace the previous bundle."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('design_source', ROOT / 'tools/update-design-skill.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.dest = self.root / 'bundle'
        self.dest.mkdir()
        (self.dest / 'keep').write_text('old bundle')
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.source / 'scripts').mkdir()
        (self.source / 'scripts/export-skill.mjs').write_text("throw new Error('fixture export failure');")
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.sha = self.git('rev-parse', 'HEAD').strip()

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.source), *args], text=True)

    def assert_old_bundle(self):
        self.assertEqual((self.dest / 'keep').read_text(), 'old bundle')
        self.assertEqual(list(self.dest.iterdir()), [self.dest / 'keep'])

    def test_export_failure_preserves_old_bundle(self):
        with self.assertRaises(subprocess.CalledProcessError):
            mod.refresh(self.source, self.sha, self.dest)
        self.assert_old_bundle()

    def test_dirty_source_preserves_old_bundle(self):
        (self.source / 'dirty').write_text('untracked')
        with self.assertRaisesRegex(ValueError, 'clean'):
            mod.refresh(self.source, self.sha, self.dest)
        self.assert_old_bundle()

    def test_wrong_revision_preserves_old_bundle(self):
        with self.assertRaisesRegex(ValueError, 'revision'):
            mod.refresh(self.source, '0' * 40, self.dest)
        self.assert_old_bundle()

    def test_success_replaces_whole_bundle_with_requested_pin(self):
        exporter = """import {mkdirSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const dest=process.argv[2]; mkdirSync(dest);
writeFileSync(dest+'/SKILL.md','new bundle');
writeFileSync(dest+'/SOURCE.json',JSON.stringify({repository:'https://github.com/vossiman/dataprospectors-design-system',revision:execFileSync('git',['-C',import.meta.dirname+'/..','rev-parse','HEAD'],{encoding:'utf8'}).trim(),themeVersion:'0.1.0',files:{'SKILL.md':createHash('sha256').update('new bundle').digest('hex')}}));
"""
        (self.source / 'scripts/export-skill.mjs').write_text(exporter)
        self.git('add', '.')
        self.git('commit', '-qm', 'successful exporter')
        sha = self.git('rev-parse', 'HEAD').strip()
        mod.refresh(self.source, sha, self.dest)
        self.assertEqual((self.dest / 'SKILL.md').read_text(), 'new bundle')
        self.assertFalse((self.dest / 'keep').exists())
        self.assertEqual(mod.check(self.dest)['revision'], sha)

    def test_check_detects_changed_missing_extra_and_escaping_files(self):
        (self.dest / 'keep').unlink()
        (self.dest / 'SKILL.md').write_text('fixture')
        import hashlib
        meta={'repository':mod.REPOSITORY,'revision':self.sha,'themeVersion':'0.1.0','files':{'SKILL.md':hashlib.sha256(b'fixture').hexdigest()}}
        (self.dest / 'SOURCE.json').write_text(json.dumps(meta))
        mod.check(self.dest)
        (self.dest / 'SKILL.md').write_text('changed')
        with self.assertRaisesRegex(ValueError,'hash'):
            mod.check(self.dest)
        (self.dest / 'SKILL.md').write_text('fixture')
        (self.dest / 'extra').write_text('extra')
        with self.assertRaisesRegex(ValueError,'inventory'):
            mod.check(self.dest)
        (self.dest / 'extra').unlink()
        (self.dest / 'SKILL.md').unlink()
        with self.assertRaisesRegex(ValueError,'inventory'):
            mod.check(self.dest)
        (self.dest / 'SKILL.md').write_text('fixture')
        meta['files']['../escape']='0'*64
        (self.dest / 'SOURCE.json').write_text(json.dumps(meta))
        with self.assertRaisesRegex(ValueError,'path'):
            mod.check(self.dest)

if __name__=='__main__': unittest.main()
