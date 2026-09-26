"""Offline verification of immutable blueprint releases and their Git evidence.

The updater attests CI selection in qualified refs after a canonical fetch.
These are local trust records, not publisher signatures. Git objects bind the
raw template and ancestry to that selection; the runtime digest detects other
release changes. This module never fetches or executes release-provided code.
"""
from pathlib import Path
import errno
import hashlib
import os
import re
import stat
import subprocess
import tempfile

CANONICAL_ORIGIN = "https://github.com/vossiman/aiCodingBaseSetup"
TEMPLATE_PATH = "configs/codex/config.toml"


class ProvenanceFailure(Exception):
    """``code`` is the stable public code; ``detail`` names the failed check.

    Details carry fixed check names plus paths relative to the public
    provenance cache, never file contents or caller configuration.
    """

    def __init__(self, code, detail=None):
        super().__init__(code)
        self.code = code
        self.detail = detail


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


def cache_git(cache, *args, stderr=subprocess.DEVNULL):
    try:
        return subprocess.run(
            ["git", "--no-replace-objects", "-c", "protocol.allow=never",
             "-c", "core.commitGraph=false", "--git-dir=" + str(cache), *args],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr,
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


def _errno_name(error):
    return errno.errorcode.get(error.errno or 0, "EIO")


def _cache_failure(detail):
    return ProvenanceFailure("invalid_provenance_cache", "verify/" + detail)


def validate_cache(cache):
    if cache is None or not cache.exists():
        raise ProvenanceFailure("revision_unavailable")
    try:
        _regular_tree(cache, "invalid_provenance_cache")
    except ProvenanceFailure:
        raise _cache_failure("cache_entry_not_regular")
    for parent in (cache.absolute(), *cache.absolute().parents):
        if parent.is_symlink():
            raise _cache_failure("path_symlink")
    for directory, dirs, files in os.walk(str(cache)):
        for path in [Path(directory)] + [Path(directory) / name for name in dirs + files]:
            try:
                metadata = path.lstat()
            except OSError as error:
                raise _cache_failure("cache_entry_vanished:%s:%s" % (
                    _errno_name(error), os.path.relpath(str(path), str(cache))))
            relative = os.path.relpath(str(path), str(cache))
            if metadata.st_uid != os.getuid():
                raise _cache_failure("cache_entry_foreign_owner:" + relative)
            if metadata.st_mode & 0o022:
                raise _cache_failure("cache_entry_writable:%04o:%s" % (
                    stat.S_IMODE(metadata.st_mode), relative))
    for relative in ("shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates"):
        if (cache / relative).exists():
            raise _cache_failure("graph_override:" + relative)
    if any((cache / "objects").rglob("*.promisor")):
        raise _cache_failure("promisor_pack")
    config = cache_git(cache, "config", "--local", "--no-includes", "--list")
    if config.returncode:
        raise _cache_failure("config_unreadable")
    for line in config.stdout.decode("utf-8").splitlines():
        key, _, value = line.partition("=")
        if (key not in {"core.repositoryformatversion", "core.filemode", "core.bare",
                        "core.logallrefupdates", "remote.origin.url", "remote.origin.fetch"}
                or key == "core.repositoryformatversion" and value != "0"):
            raise _cache_failure("unexpected_config_key:" + re.sub(r"[^A-Za-z0-9._-]", "?", key))
    bare = cache_git(cache, "rev-parse", "--is-bare-repository")
    if bare.returncode or bare.stdout.strip() != b"true":
        raise _cache_failure("not_bare_repository")
    origin = cache_git(cache, "config", "--local", "--no-includes", "--get", "remote.origin.url")
    if origin.returncode or canonical_origin(origin.stdout.decode("utf-8").strip()) != CANONICAL_ORIGIN:
        raise _cache_failure("origin_mismatch")
    replace = cache_git(cache, "for-each-ref", "--format=%(refname)", "refs/replace/")
    if replace.returncode or replace.stdout.strip():
        raise _cache_failure("replace_refs_present")
    # cat-file/show do not themselves verify every object's content hash.
    # Validate the full graph before trusting ancestry, with no alternate,
    # replacement, promisor or commit-graph lookup paths in play.
    fsck = cache_git(cache, "fsck", "--full", "--no-reflogs", "--no-dangling", stderr=subprocess.PIPE)
    if fsck.returncode:
        lines = fsck.stderr.decode("utf-8", "replace").splitlines()
        first = next((line for line in lines if re.match(r"(error|fatal|missing|broken)", line)),
                     lines[0] if lines else "")
        raise _cache_failure("fsck_failed:%d:%s" % (
            fsck.returncode, re.sub(r"[^A-Za-z0-9 ._:/-]", "?", first)[:120]))


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
