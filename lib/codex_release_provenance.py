"""Offline verification of immutable blueprint releases and their Git evidence.

The updater attests CI selection in qualified refs after a canonical fetch.
These are local trust records, not publisher signatures. Git objects bind the
raw template and ancestry to that selection; the runtime digest detects other
release changes. This module never fetches or executes release-provided code.
"""
from pathlib import Path
import hashlib
import os
import re
import stat
import subprocess
import tempfile

CANONICAL_ORIGIN = "https://github.com/vossiman/aiCodingBaseSetup"
TEMPLATE_PATH = "configs/codex/config.toml"


class ProvenanceFailure(Exception):
    pass


def canonical_origin(origin):
    candidate = origin.rstrip("/")
    if candidate.endswith(".git"):
        candidate = candidate[:-4]
    if candidate.lower() in {
        CANONICAL_ORIGIN.lower(),
        "ssh://github.com/vossiman/aicodingbasesetup",
        "ssh-scp://github.com:vossiman/aicodingbasesetup",
        "git@github.com:vossiman/aicodingbasesetup",
        "ssh://git@github.com/vossiman/aicodingbasesetup",
    }:
        return CANONICAL_ORIGIN
    return origin


def git_environment():
    # None of the caller's repository/config/object lookup overrides may
    # redirect evidence reads or trigger a lazy promisor fetch.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS="1",
               GIT_NO_LAZY_FETCH="1")
    return env


def cache_git(cache, *args):
    try:
        return subprocess.run(
            ["git", "--no-replace-objects", "-c", "protocol.allow=never",
             "-c", "core.commitGraph=false", "--git-dir=" + str(cache), *args],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=git_environment(), timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise ProvenanceFailure("revision_unavailable")


def _regular_tree(root, code):
    if root.is_symlink() or not root.is_dir():
        raise ProvenanceFailure(code)
    def failed(_error):
        raise ProvenanceFailure(code)
    for directory, dirs, files in os.walk(str(root), onerror=failed, followlinks=False):
        for name in dirs + files:
            mode = (Path(directory) / name).lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise ProvenanceFailure(code)


def validate_cache(cache):
    if cache is None or not cache.exists():
        raise ProvenanceFailure("revision_unavailable")
    _regular_tree(cache, "invalid_provenance_cache")
    for parent in (cache.absolute(), *cache.absolute().parents):
        if parent.is_symlink():
            raise ProvenanceFailure("invalid_provenance_cache")
    for directory, dirs, files in os.walk(str(cache)):
        for path in [Path(directory)] + [Path(directory) / name for name in dirs + files]:
            metadata = path.lstat()
            if metadata.st_uid != os.getuid() or metadata.st_mode & 0o022:
                raise ProvenanceFailure("invalid_provenance_cache")
    for relative in ("shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates"):
        if (cache / relative).exists():
            raise ProvenanceFailure("invalid_provenance_cache")
    if any((cache / "objects").rglob("*.promisor")):
        raise ProvenanceFailure("invalid_provenance_cache")
    config = cache_git(cache, "config", "--local", "--no-includes", "--list")
    if config.returncode:
        raise ProvenanceFailure("invalid_provenance_cache")
    for line in config.stdout.decode("utf-8").splitlines():
        key, _, value = line.partition("=")
        if (key not in {"core.repositoryformatversion", "core.filemode", "core.bare",
                        "core.logallrefupdates", "remote.origin.url", "remote.origin.fetch"}
                or key == "core.repositoryformatversion" and value != "0"):
            raise ProvenanceFailure("invalid_provenance_cache")
    bare = cache_git(cache, "rev-parse", "--is-bare-repository")
    origin = cache_git(cache, "config", "--local", "--no-includes", "--get", "remote.origin.url")
    replace = cache_git(cache, "for-each-ref", "--format=%(refname)", "refs/replace/")
    if (bare.returncode or bare.stdout.strip() != b"true" or origin.returncode
            or canonical_origin(origin.stdout.decode("utf-8").strip()) != CANONICAL_ORIGIN
            or replace.returncode or replace.stdout.strip()):
        raise ProvenanceFailure("invalid_provenance_cache")
    # cat-file/show do not themselves verify every object's content hash.
    # Validate the full graph before trusting ancestry, with no alternate,
    # replacement, promisor or commit-graph lookup paths in play.
    if cache_git(cache, "fsck", "--full", "--no-reflogs", "--no-dangling").returncode:
        raise ProvenanceFailure("invalid_provenance_cache")


def verify_release(root, template, template_raw, cache):
    _regular_tree(root, "invalid_blueprint_release")
    try:
        revision = (root / ".aicoding-version").read_text().strip()
        expected = (root / ".aicoding-tree.sha256").read_text().strip()
    except OSError:
        raise ProvenanceFailure("invalid_blueprint_release")
    if not re.fullmatch(r"[0-9a-f]{40}", revision) or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ProvenanceFailure("invalid_blueprint_release")
    if template.resolve() != (root / TEMPLATE_PATH).resolve():
        raise ProvenanceFailure("invalid_blueprint_release")
    env = dict(os.environ)
    env.pop("TAR_OPTIONS", None)
    with tempfile.TemporaryFile() as archive:
        try:
            result = subprocess.run(
                ["tar", "-C", str(root), "--sort=name", "--mtime=@0", "--owner=0", "--group=0",
                 "--numeric-owner", "--format=gnu", "--exclude=./.aicoding-tree.sha256", "-cf", "-", "."],
                stdin=subprocess.DEVNULL, stdout=archive, stderr=subprocess.DEVNULL, env=env, timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            raise ProvenanceFailure("invalid_blueprint_release")
        archive.seek(0)
        digest = hashlib.sha256()
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
        if result.returncode or digest.hexdigest() != expected:
            raise ProvenanceFailure("invalid_blueprint_release")
    validate_cache(cache)
    qualified = cache_git(cache, "rev-parse", "--verify", "refs/aicoding/qualified/" + revision)
    if qualified.returncode or qualified.stdout.strip().decode("ascii") != revision:
        raise ProvenanceFailure("revision_unavailable")
    commit = cache_git(cache, "cat-file", "-t", revision)
    if commit.returncode or commit.stdout.strip() != b"commit":
        raise ProvenanceFailure("revision_unavailable")
    blob = cache_git(cache, "show", revision + ":" + TEMPLATE_PATH)
    if blob.returncode or blob.stdout != template_raw:
        raise ProvenanceFailure("invalid_blueprint_release")
    return revision
