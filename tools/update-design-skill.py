#!/usr/bin/env python3
"""Refresh/check the vendored design skill; installation itself never fetches it."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit, unquote

REPOSITORY = 'https://github.com/vossiman/dataprospectors-design-system'
DESTINATION = Path(__file__).resolve().parents[1] / 'skills/dataprospectors-design'


def check(dest):
    dest = Path(dest)
    metadata = json.loads((dest / 'SOURCE.json').read_text())
    if metadata.get('repository') != REPOSITORY or not re.fullmatch(r'[a-f0-9]{40}', metadata.get('revision', '')):
        raise ValueError('Invalid repository/revision provenance')
    files = metadata.get('files', {})
    if not isinstance(files, dict) or 'SKILL.md' not in files:
        raise ValueError('Invalid file inventory')
    for name in files:
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or str(path) != name or name == 'SOURCE.json':
            raise ValueError('Invalid manifest path')
    paths = list(dest.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError('Bundle contains a symlink path')
    actual = {path.relative_to(dest).as_posix() for path in paths if path.is_file()} - {'SOURCE.json'}
    if actual != set(files):
        raise ValueError('Bundle file inventory differs from source manifest')
    for name, expected in files.items():
        if hashlib.sha256((dest / name).read_bytes()).hexdigest() != expected:
            raise ValueError(f'Bundle hash mismatch: {name}')
    return metadata


def canonical_origin(origin):
    """Recognize the canonical repo through common HTTPS/SSH transports."""
    if re.fullmatch(r'git@github\.com:vossiman/dataprospectors-design-system(?:\.git)?/?', origin, re.I):
        return True
    try:
        url = urlsplit(origin)
        if '?' in origin or '#' in origin or url.hostname != 'github.com' or url.password:
            return False
        if url.scheme == 'https':
            if url.username or url.port not in (None, 443):
                return False
        elif url.scheme == 'ssh':
            if url.username not in (None, 'git') or url.port not in (None, 22):
                return False
        else:
            return False
        return unquote(url.path).lower().rstrip('/').removesuffix('.git') == '/vossiman/dataprospectors-design-system'
    except ValueError:
        return False


def refresh(source, revision, dest=DESTINATION):
    source, dest = Path(source).resolve(), Path(dest).resolve()
    if not re.fullmatch(r'[a-f0-9]{40}', revision):
        raise ValueError('A full 40-character revision is required')
    def git(*args):
        return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()
    if git('rev-parse', 'HEAD') != revision:
        raise ValueError('Source HEAD differs from requested revision')
    if git('status', '--porcelain'):
        raise ValueError('Source checkout must be clean')
    origin = subprocess.run(['git', '-C', str(source), 'remote', 'get-url', 'origin'],
                            capture_output=True, text=True)
    if origin.returncode or not canonical_origin(origin.stdout.strip()):
        # Never echo origin: an operator's URL could contain credentials.
        raise ValueError('Source origin must identify the canonical design repository')

    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.design-skill-', dir=dest.parent) as tmp:
        staged = Path(tmp) / 'bundle'
        subprocess.run(['node', str(source / 'scripts/export-skill.mjs'), str(staged)], check=True)
        metadata = check(staged)
        if metadata['revision'] != revision:
            raise ValueError('Export revision differs from requested revision')
        backup = Path(tmp) / 'previous'
        if dest.exists():
            dest.rename(backup)
        try:
            staged.rename(dest)
        except BaseException:
            if backup.exists():
                backup.rename(dest)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check committed bundle without network or source checkout')
    parser.add_argument('--source', type=Path, help='Clean private design-system checkout')
    parser.add_argument('--revision', help='Exact reviewed full source SHA')
    args = parser.parse_args()
    try:
        if args.check:
            if args.source or args.revision:
                parser.error('--check cannot be combined with refresh arguments')
            metadata = check(DESTINATION)
            print('Design skill bundle verified at ' + metadata['revision'])
        else:
            if not args.source or not args.revision:
                parser.error('refresh requires --source and --revision')
            refresh(args.source, args.revision)
            print('Design skill bundle refreshed at ' + args.revision)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
