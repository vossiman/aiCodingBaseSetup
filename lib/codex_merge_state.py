"""Filesystem, receipt, provenance, and locking adapter for Codex TOML merge."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Any, Dict, Iterator, List, Mapping, Optional, Sequence, Tuple
from urllib.parse import urlsplit, urlunsplit

from codex_merge import MergePlan, plan_merge, validate_acknowledged
from codex_release_provenance import (CANONICAL_ORIGIN, ProvenanceFailure,
    canonical_origin, git_environment, verify_release)


RECEIPT_VERSION = 1
STATE_DIRECTORY = ".aicoding-sync"
STATE_FILENAME = "config-state.json"
LOCK_FILENAME = "lock"
PROFILES = frozenset(("host", "container"))
SOURCE_KINDS = frozenset(("tracking", "local"))
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
REVISION_RE = re.compile(r"^[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?$")
_NO_EXPECTATION = object()


@dataclass(frozen=True)
class Request:
    action: str
    source: Path
    template: Path
    dest: Path
    clone: Path
    profile: str
    local: bool = False
    tracked: bool = False
    allow_adopt: bool = False
    expected: Optional[str] = None
    decisions: Sequence[Mapping[str, Any]] = ()
    provenance_git: Optional[Path] = None


@dataclass
class _Prepared:
    request: Request
    source_raw: bytes
    template_raw: bytes
    local_raw: Optional[bytes]
    receipt_raw: Optional[bytes]
    receipt: Optional[Dict[str, Any]]
    candidate_receipt: Optional[Dict[str, Any]]
    plan: Optional[MergePlan]
    provenance: Dict[str, Any]
    token: str
    unmanaged: bool


class RequestFailure(Exception):
    def __init__(self, code: str, **safe_details: Any) -> None:
        super().__init__(code)
        self.diagnostic = {"code": code}
        self.diagnostic.update(safe_details)


class ConcurrentChange(Exception):
    pass


def state_path_for(dest: Path) -> Path:
    return Path(dest).parent / STATE_DIRECTORY / STATE_FILENAME


def lock_path_for(dest: Path) -> Path:
    return state_path_for(dest).parent / LOCK_FILENAME


def _error_payload(diagnostic: Dict[str, Any], *, apply: bool) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "config_changed": False,
        "state_changed": False,
        "conflicts": [],
        "error": diagnostic,
        "unmanaged": False,
        "token": None,
        "changes": [],
        "adoption_notices": [],
    }
    if apply:
        payload["applied"] = False
    return payload


def error_result(code: str, *, apply: bool, **safe_details: Any) -> Tuple[Dict[str, Any], int]:
    diagnostic = {"code": code}
    diagnostic.update(safe_details)
    return _error_payload(diagnostic, apply=apply), 2


def _read_required(path: Path, code: str) -> bytes:
    try:
        return Path(path).read_bytes()
    except (OSError, ValueError):
        raise RequestFailure(code)


def _read_optional(path: Path, code: str) -> Optional[bytes]:
    try:
        return Path(path).read_bytes()
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise RequestFailure(code)


def _decode(raw: bytes, code: str) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise RequestFailure(code)


def _run_git(clone: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    try:
        completed = subprocess.run(
            ["git", "--no-replace-objects", "-c", "protocol.allow=never",
             "-c", "core.commitGraph=false", "-C", str(clone), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=git_environment(),
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise RequestFailure("git_unavailable")
    if check and completed.returncode != 0:
        raise RequestFailure("invalid_blueprint_clone")
    return completed


def _sanitize_origin(origin: str, clone: Path) -> str:
    origin = origin.strip()
    parsed = urlsplit(origin)
    if parsed.scheme in ("http", "https", "ssh", "git"):
        hostname = parsed.hostname or ""
        if parsed.port is not None:
            hostname += ":{}".format(parsed.port)
        return urlunsplit((parsed.scheme.lower(), hostname.lower(), parsed.path, "", ""))
    if parsed.scheme == "file":
        return "file://" + str(Path(parsed.path).resolve())
    if ":" in origin and "@" in origin.split(":", 1)[0]:
        host_path = origin.split("@", 1)[1]
        return "ssh-scp://" + host_path
    candidate = Path(origin)
    if not candidate.is_absolute():
        candidate = Path(clone) / candidate
    return "file://" + str(candidate.resolve())


def _discover_provenance(request: Request, template_raw: bytes) -> Dict[str, Any]:
    clone = Path(request.clone)
    if not request.local and not (clone / ".git").exists():
        try:
            revision = verify_release(clone, request.template, template_raw, request.provenance_git)
        except ProvenanceFailure as failure:
            raise RequestFailure(str(failure))
        return {"origin": CANONICAL_ORIGIN, "revision": revision,
                "template_sha256": "sha256:" + hashlib.sha256(template_raw).hexdigest(),
                "source_kind": "tracking", "profile": request.profile}
    origin_result = _run_git(clone, "remote", "get-url", "origin")
    origin = canonical_origin(_sanitize_origin(origin_result.stdout, clone))
    head = _run_git(clone, "rev-parse", "HEAD").stdout.strip().lower()
    if not REVISION_RE.match(head):
        raise RequestFailure("invalid_blueprint_clone")
    dirty = bool(
        _run_git(clone, "status", "--porcelain", "--untracked-files=all").stdout.strip()
    )

    origin_main_result = _run_git(
        clone, "rev-parse", "--verify", "refs/remotes/origin/main", check=False
    )
    origin_main = (
        origin_main_result.stdout.strip().lower()
        if origin_main_result.returncode == 0
        else None
    )

    if request.local:
        source_kind = "tracking" if not dirty and origin_main == head else "local"
    else:
        if dirty:
            raise RequestFailure("dirty_tracking_clone")
        source_kind = "tracking"

    return {
        "origin": origin,
        "revision": head if not dirty else None,
        "template_sha256": "sha256:" + hashlib.sha256(template_raw).hexdigest(),
        "source_kind": source_kind,
        "profile": request.profile,
    }


def _validate_provenance_shape(provenance: Any) -> bool:
    if not isinstance(provenance, dict):
        return False
    if set(provenance) != {
        "origin",
        "revision",
        "template_sha256",
        "source_kind",
        "profile",
    }:
        return False
    revision = provenance.get("revision")
    return (
        isinstance(provenance.get("origin"), str)
        and bool(provenance["origin"])
        and (revision is None or isinstance(revision, str) and REVISION_RE.match(revision))
        and isinstance(provenance.get("template_sha256"), str)
        and bool(HASH_RE.match(provenance["template_sha256"]))
        and provenance.get("source_kind") in SOURCE_KINDS
        and provenance.get("profile") in PROFILES
    )


def _load_receipt(raw: Optional[bytes]) -> Optional[Dict[str, Any]]:
    if raw is None:
        return None
    try:
        receipt = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise RequestFailure("invalid_receipt")
    if not isinstance(receipt, dict):
        raise RequestFailure("invalid_receipt")
    version = receipt.get("version")
    if type(version) is not int:
        raise RequestFailure("invalid_receipt")
    if version != RECEIPT_VERSION:
        raise RequestFailure("unsupported_receipt_version")
    if set(receipt) != {"version", "provenance", "managed"}:
        raise RequestFailure("invalid_receipt")
    if not _validate_provenance_shape(receipt.get("provenance")):
        raise RequestFailure("invalid_receipt")
    if not validate_acknowledged(receipt.get("managed")):
        raise RequestFailure("invalid_receipt")
    return receipt


def _git_has_commit(clone: Path, revision: str) -> bool:
    result = _run_git(clone, "cat-file", "-e", revision + "^{commit}", check=False)
    return result.returncode == 0


def _is_ancestor(clone: Path, older: str, newer: str) -> Optional[bool]:
    result = _run_git(clone, "merge-base", "--is-ancestor", older, newer, check=False)
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    return None


def _validate_provenance(
    request: Request,
    recorded: Dict[str, Any],
    incoming: Dict[str, Any],
) -> None:
    if canonical_origin(recorded["origin"]) != canonical_origin(incoming["origin"]):
        raise RequestFailure("origin_mismatch")
    if recorded["profile"] != incoming["profile"]:
        raise RequestFailure(
            "profile_mismatch",
            recorded_profile=recorded["profile"],
            incoming_profile=incoming["profile"],
        )

    if recorded["source_kind"] == "local":
        if not request.local:
            raise RequestFailure("local_to_tracking_refused")
        return

    # An explicit local blueprint selection may deliberately move between
    # revisions. Ordinary tracking callers must prove monotonic ancestry.
    if request.local:
        return
    recorded_revision = recorded.get("revision")
    incoming_revision = incoming.get("revision")
    evidence = request.provenance_git if not (request.clone / ".git").exists() and not request.local else request.clone
    if evidence is None or not recorded_revision or not _git_has_commit(evidence, recorded_revision):
        raise RequestFailure("revision_unavailable")
    if not incoming_revision:
        raise RequestFailure("invalid_blueprint_clone")
    if recorded_revision == incoming_revision:
        return
    newer = _is_ancestor(evidence, recorded_revision, incoming_revision)
    if newer is True:
        return
    older = _is_ancestor(evidence, incoming_revision, recorded_revision)
    if older is True:
        raise RequestFailure("older_revision")
    if newer is None or older is None:
        raise RequestFailure("revision_unavailable")
    raise RequestFailure("divergent_revision")


def _normalize_decisions(
    decisions: Sequence[Mapping[str, Any]],
) -> Dict[Tuple[str, ...], str]:
    if not isinstance(decisions, (list, tuple)):
        raise RequestFailure("invalid_decisions")
    normalized: Dict[Tuple[str, ...], str] = {}
    for decision in decisions:
        if not isinstance(decision, Mapping) or set(decision) != {"path", "choice"}:
            raise RequestFailure("invalid_decisions")
        path = decision.get("path")
        choice = decision.get("choice")
        if (
            not isinstance(path, list)
            or not path
            or not all(isinstance(segment, str) for segment in path)
            or choice not in ("local", "blueprint")
        ):
            raise RequestFailure("invalid_decisions")
        path_tuple = tuple(path)
        if path_tuple in normalized:
            raise RequestFailure("invalid_decisions")
        normalized[path_tuple] = choice
    return normalized


def load_decisions(path: Optional[Path]) -> List[Mapping[str, Any]]:
    if path is None:
        return []
    try:
        raw = Path(path).read_bytes()
    except (OSError, ValueError):
        raise RequestFailure("decisions_read_failed")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise RequestFailure("invalid_decisions")
    if not isinstance(value, list):
        raise RequestFailure("invalid_decisions")
    return value


def _plan_token(
    request: Request,
    source_raw: bytes,
    template_raw: bytes,
    local_raw: Optional[bytes],
    receipt_raw: Optional[bytes],
    provenance: Dict[str, Any],
    adoption: bool,
) -> str:
    digest = hashlib.sha256()
    parts = (
        ("source", source_raw),
        ("template", template_raw),
        ("config", b"<missing>" if local_raw is None else local_raw),
        ("receipt", b"<missing>" if receipt_raw is None else receipt_raw),
        ("provenance", json.dumps(provenance, sort_keys=True, separators=(",", ":")).encode("utf-8")),
        ("profile", request.profile.encode("ascii")),
        ("local", b"1" if request.local else b"0"),
        ("tracked", b"1" if request.tracked else b"0"),
        ("adoption", b"1" if adoption else b"0"),
    )
    for label, value in parts:
        encoded_label = label.encode("ascii")
        digest.update(len(encoded_label).to_bytes(2, "big"))
        digest.update(encoded_label)
        digest.update(hashlib.sha256(value).digest())
    return "plan-v1:" + digest.hexdigest()


def _prepare(request: Request) -> _Prepared:
    if request.action not in ("plan", "apply") or request.profile not in PROFILES:
        raise RequestFailure("invalid_request")
    source_raw = _read_required(Path(request.source), "source_read_failed")
    template_raw = _read_required(Path(request.template), "template_read_failed")
    local_raw = _read_optional(Path(request.dest), "destination_read_failed")
    receipt_path = state_path_for(Path(request.dest))
    receipt_raw = _read_optional(receipt_path, "receipt_read_failed")
    receipt = _load_receipt(receipt_raw)
    provenance = _discover_provenance(request, template_raw)
    if receipt is not None:
        _validate_provenance(request, receipt["provenance"], provenance)

    source_text = _decode(source_raw, "invalid_source_toml")
    local_text = None if local_raw is None else _decode(local_raw, "invalid_destination_toml")
    adoption = local_raw is not None and receipt is None and (
        request.tracked or request.allow_adopt
    )
    unmanaged = local_raw is not None and receipt is None and not adoption
    acknowledged = receipt["managed"] if receipt is not None else None
    base_plan = plan_merge(
        local_text,
        source_text,
        acknowledged=acknowledged,
        adoption=adoption,
    )
    if base_plan.error is not None:
        raise RequestFailure(base_plan.error["code"])

    token = _plan_token(
        request,
        source_raw,
        template_raw,
        local_raw,
        receipt_raw,
        provenance,
        adoption,
    )
    decisions = _normalize_decisions(request.decisions)
    if decisions and request.expected is None:
        raise RequestFailure("expected_token_required")
    if request.expected is not None and request.expected != token:
        raise RequestFailure("stale_plan")

    if unmanaged:
        if decisions:
            raise RequestFailure("unknown_decision_path")
        return _Prepared(
            request=request,
            source_raw=source_raw,
            template_raw=template_raw,
            local_raw=local_raw,
            receipt_raw=receipt_raw,
            receipt=receipt,
            candidate_receipt=None,
            plan=None,
            provenance=provenance,
            token=token,
            unmanaged=True,
        )

    actionable = {
        tuple(item["path"])
        for item in base_plan.conflicts + base_plan.adoption_notices
    }
    if any(path not in actionable for path in decisions):
        raise RequestFailure("unknown_decision_path")
    final_plan = (
        plan_merge(
            local_text,
            source_text,
            acknowledged=acknowledged,
            decisions=decisions,
            adoption=adoption,
        )
        if decisions
        else base_plan
    )
    if final_plan.error is not None:
        raise RequestFailure(final_plan.error["code"])
    candidate_receipt = {
        "version": RECEIPT_VERSION,
        "provenance": provenance,
        "managed": final_plan.acknowledged,
    }
    final_plan.state_changed = candidate_receipt != receipt
    return _Prepared(
        request=request,
        source_raw=source_raw,
        template_raw=template_raw,
        local_raw=local_raw,
        receipt_raw=receipt_raw,
        receipt=receipt,
        candidate_receipt=candidate_receipt,
        plan=final_plan,
        provenance=provenance,
        token=token,
        unmanaged=False,
    )


def _public(prepared: _Prepared, *, apply: bool, applied: bool = False) -> Dict[str, Any]:
    if prepared.unmanaged:
        payload: Dict[str, Any] = {
            "config_changed": False,
            "state_changed": False,
            "conflicts": [],
            "error": None,
            "unmanaged": True,
            "token": prepared.token,
            "changes": [],
            "adoption_notices": [],
        }
    else:
        assert prepared.plan is not None
        payload = {
            "config_changed": prepared.plan.config_changed,
            "state_changed": prepared.plan.state_changed,
            "conflicts": prepared.plan.conflicts,
            "error": None,
            "unmanaged": False,
            "token": prepared.token,
            "changes": prepared.plan.changes,
            "adoption_notices": prepared.plan.adoption_notices,
        }
    if apply:
        payload["applied"] = applied
    return payload


def _failure_from_plan(prepared: _Prepared, code: str) -> Dict[str, Any]:
    payload = _public(prepared, apply=True, applied=False)
    payload["error"] = {"code": code}
    return payload


def _canonical_receipt(receipt: Dict[str, Any]) -> bytes:
    return (
        json.dumps(receipt, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def atomic_write(
    path: Path,
    content: bytes,
    mode: int = 0o600,
    *,
    expected: Any = _NO_EXPECTATION,
) -> None:
    """Replace a file atomically, optionally rechecking its exact live bytes."""

    path = Path(path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix="." + path.name + ".tmp.", dir=str(path.parent)
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if expected is not _NO_EXPECTATION:
            live = _read_optional(path, "concurrent_read_failed")
            if live != expected:
                raise ConcurrentChange()
        os.replace(str(temporary), str(path))
        directory_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@contextmanager
def _shared_lock(dest: Path) -> Iterator[None]:
    dest_parent = Path(dest).parent
    dest_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    state_directory = state_path_for(dest).parent
    state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(str(state_directory), 0o700)
    lock_path = lock_path_for(dest)
    descriptor = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _snapshot_matches(prepared: _Prepared) -> bool:
    return (
        _read_optional(Path(prepared.request.dest), "destination_read_failed")
        == prepared.local_raw
        and _read_optional(
            state_path_for(Path(prepared.request.dest)), "receipt_read_failed"
        )
        == prepared.receipt_raw
    )


def _apply_prepared(prepared: _Prepared) -> Tuple[Dict[str, Any], int]:
    assert prepared.plan is not None
    assert prepared.candidate_receipt is not None
    if not _snapshot_matches(prepared):
        return _failure_from_plan(prepared, "changed_during_apply"), 2

    if prepared.plan.config_changed:
        try:
            atomic_write(
                Path(prepared.request.dest),
                prepared.plan.config_text.encode("utf-8"),
                0o600,
                expected=prepared.local_raw,
            )
        except ConcurrentChange:
            return _failure_from_plan(prepared, "changed_during_apply"), 2
        except (OSError, RequestFailure):
            return _failure_from_plan(prepared, "config_write_failed"), 2

    if prepared.plan.state_changed:
        try:
            atomic_write(
                state_path_for(Path(prepared.request.dest)),
                _canonical_receipt(prepared.candidate_receipt),
                0o600,
                expected=prepared.receipt_raw,
            )
        except (ConcurrentChange, OSError, RequestFailure):
            return _failure_from_plan(prepared, "receipt_write_failed"), 2

    return _public(prepared, apply=True, applied=True), 0


def execute(request: Request) -> Tuple[Dict[str, Any], int]:
    """Execute one public plan/apply request and return value-safe JSON data."""

    is_apply = request.action == "apply"
    try:
        prepared = _prepare(request)
        if not is_apply:
            return _public(prepared, apply=False), 0
        if prepared.unmanaged:
            return _public(prepared, apply=True, applied=False), 0

        try:
            with _shared_lock(Path(request.dest)):
                # The authoritative plan is always recomputed after acquiring
                # the shared receipt lock.
                prepared = _prepare(request)
                if prepared.unmanaged:
                    return _public(prepared, apply=True, applied=False), 0
                return _apply_prepared(prepared)
        except RequestFailure:
            raise
        except OSError:
            raise RequestFailure("lock_failed")
    except RequestFailure as failure:
        return _error_payload(failure.diagnostic, apply=is_apply), 2
    except Exception:
        # Parser, git, and OS exception strings can include configuration text
        # or paths. Public failures are deliberately fixed diagnostics.
        return _error_payload({"code": "internal_error"}, apply=is_apply), 2
