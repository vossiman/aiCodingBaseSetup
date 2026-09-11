#!/usr/bin/env python3
"""Behavioral tests for the Codex TOML merge engine and CLI."""

import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True


ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib"
sys.path.insert(0, str(LIB))

from codex_merge import fingerprint_value, plan_merge  # noqa: E402
from codex_merge_state import Request, execute, state_path_for  # noqa: E402


class PureMergeTests(unittest.TestCase):
    def baseline(self, text):
        plan = plan_merge(None, text)
        self.assertIsNone(plan.error)
        return plan

    def test_typed_fingerprints_are_semantic_and_type_aware(self):
        self.assertNotEqual(fingerprint_value(True), fingerprint_value(1))
        self.assertNotEqual(fingerprint_value(1), fingerprint_value(1.0))
        self.assertNotEqual(
            fingerprint_value(dt.date(2026, 9, 11)),
            fingerprint_value("2026-09-11"),
        )
        self.assertEqual(
            fingerprint_value({"b": 2, "a": 1}),
            fingerprint_value({"a": 1, "b": 2}),
        )
        self.assertNotEqual(fingerprint_value([1, 2]), fingerprint_value([2, 1]))
        self.assertEqual(fingerprint_value(float("nan")), fingerprint_value(math.nan))
        self.assertNotEqual(
            fingerprint_value(float("inf")), fingerprint_value(float("-inf"))
        )

    def test_user_owned_model_and_projects_survive_safe_blueprint_update(self):
        installed = self.baseline(
            'model = "gpt-5.6-sol"\n\n[tui]\nalternate_screen = "never"\n'
        )
        local = (
            '# personal\nmodel = "gpt-6-astra"\n\n'
            '[tui]\nalternate_screen = "never"\n\n'
            '[projects."/work/trusted"]\ntrust_level = "trusted"\n\n'
            '[projects."/work/untrusted"]\ntrust_level = "untrusted"\n'
        )
        incoming = (
            'model = "gpt-5.6-sol"\n\n[tui]\nalternate_screen = "auto"\n'
        )

        plan = plan_merge(local, incoming, acknowledged=installed.acknowledged)

        self.assertEqual(plan.conflicts, [])
        self.assertTrue(plan.config_changed)
        self.assertIn('model = "gpt-6-astra"', plan.config_text)
        self.assertIn('alternate_screen = "auto"', plan.config_text)
        self.assertIn('[projects."/work/trusted"]', plan.config_text)
        self.assertIn('[projects."/work/untrusted"]', plan.config_text)

        repeat = plan_merge(
            plan.config_text, incoming, acknowledged=plan.acknowledged
        )
        self.assertFalse(repeat.config_changed)
        self.assertEqual(repeat.config_text, plan.config_text)
        self.assertEqual(repeat.conflicts, [])

    def test_four_three_way_rows_and_explicit_acknowledgment(self):
        base = self.baseline("x = 1\n").acknowledged

        equal_incoming = plan_merge("x = 2\n", "x = 2\n", acknowledged=base)
        self.assertFalse(equal_incoming.config_changed)
        self.assertEqual(equal_incoming.conflicts, [])

        local_only = plan_merge("x = 2\n", "x = 1\n", acknowledged=base)
        self.assertFalse(local_only.config_changed)
        self.assertEqual(local_only.conflicts, [])
        self.assertEqual(local_only.acknowledged, base)

        blueprint_only = plan_merge("x = 1\n", "x = 2\n", acknowledged=base)
        self.assertEqual(blueprint_only.config_text, "x = 2\n")
        self.assertEqual(blueprint_only.conflicts, [])

        conflict = plan_merge("x = 2\n", "x = 3\n", acknowledged=base)
        self.assertEqual(conflict.config_text, "x = 2\n")
        self.assertEqual(conflict.conflicts, [{"path": ["x"]}])
        self.assertEqual(conflict.acknowledged, base)

        keep = plan_merge(
            "x = 2\n",
            "x = 3\n",
            acknowledged=base,
            decisions={("x",): "local"},
        )
        self.assertEqual(keep.config_text, "x = 2\n")
        self.assertEqual(keep.conflicts, [])
        repeat = plan_merge("x = 2\n", "x = 3\n", acknowledged=keep.acknowledged)
        self.assertEqual(repeat.conflicts, [])
        later = plan_merge("x = 2\n", "x = 4\n", acknowledged=keep.acknowledged)
        self.assertEqual(later.conflicts, [{"path": ["x"]}])

        take = plan_merge(
            "x = 2\n",
            "x = 3\n",
            acknowledged=base,
            decisions={("x",): "blueprint"},
        )
        self.assertEqual(take.config_text, "x = 3\n")
        self.assertEqual(take.conflicts, [])

    def test_nested_removals_and_type_changes_compare_the_parent(self):
        table_base = self.baseline("[service]\nport = 80\n").acknowledged

        safe_remove = plan_merge(
            "[service]\nport = 80\n", "title = \"new\"\n", acknowledged=table_base
        )
        self.assertNotIn("[service]", safe_remove.config_text)
        self.assertIn({"path": ["service"], "operation": "remove"}, safe_remove.changes)

        local_child = plan_merge(
            "[service]\nport = 80\nlabel = \"mine\"\n",
            "title = \"new\"\n",
            acknowledged=table_base,
        )
        self.assertEqual(local_child.conflicts, [{"path": ["service"]}])
        self.assertIn("label = \"mine\"", local_child.config_text)

        scalar_base = self.baseline("service = 1\n").acknowledged
        type_update = plan_merge(
            "service = 1\n", "[service]\nport = 443\n", acknowledged=scalar_base
        )
        self.assertEqual(type_update.conflicts, [])
        self.assertIn("[service]", type_update.config_text)

        type_conflict = plan_merge(
            "service = 2\n", "[service]\nport = 443\n", acknowledged=scalar_base
        )
        self.assertEqual(type_conflict.conflicts, [{"path": ["service"]}])
        self.assertEqual(type_conflict.config_text, "service = 2\n")

        introduced_collision = plan_merge(
            "service = 2\n", "[service]\nport = 443\n", acknowledged=None
        )
        self.assertEqual(introduced_collision.conflicts, [{"path": ["service"]}])

    def test_new_compatible_table_preserves_local_only_children(self):
        plan = plan_merge(
            "[tui]\nstatus_line = [\"model-name\"]\n",
            "[tui]\nalternate_screen = \"auto\"\n",
            acknowledged=None,
        )
        self.assertEqual(plan.conflicts, [])
        self.assertIn('status_line = ["model-name"]', plan.config_text)
        self.assertIn('alternate_screen = "auto"', plan.config_text)

    def test_arrays_are_atomic(self):
        base = self.baseline('notify = ["one", "two"]\n').acknowledged
        conflict = plan_merge(
            'notify = ["mine"]\n', 'notify = ["upstream"]\n', acknowledged=base
        )
        self.assertEqual(conflict.conflicts, [{"path": ["notify"]}])
        self.assertEqual(conflict.config_text, 'notify = ["mine"]\n')

    def test_mixed_acknowledged_parent_recomputes_from_each_child(self):
        base = self.baseline("[t]\na = 1\nb = 1\n").acknowledged
        mixed = plan_merge(
            "[t]\na = 2\nb = 1\n",
            "[t]\na = 3\nb = 2\n",
            acknowledged=base,
        )
        self.assertEqual(mixed.conflicts, [{"path": ["t", "a"]}])
        self.assertIn("a = 2", mixed.config_text)
        self.assertIn("b = 2", mixed.config_text)
        self.assertEqual(
            mixed.acknowledged["children"]["t"]["children"]["a"],
            base["children"]["t"]["children"]["a"],
        )
        self.assertNotEqual(
            mixed.acknowledged["children"]["t"]["children"]["b"],
            base["children"]["t"]["children"]["b"],
        )

        removed_parent = plan_merge(
            mixed.config_text, "", acknowledged=mixed.acknowledged
        )
        self.assertEqual(removed_parent.conflicts, [{"path": ["t"]}])

    def test_credential_rotation_updates_unchanged_and_conflicts_with_local_edit(self):
        base = self.baseline('[mcp_servers.private]\ntoken = "token-old"\n').acknowledged
        rotated = plan_merge(
            '[mcp_servers.private]\ntoken = "token-old"\n',
            '[mcp_servers.private]\ntoken = "token-new"\n',
            acknowledged=base,
        )
        self.assertIn('token = "token-new"', rotated.config_text)
        self.assertEqual(rotated.conflicts, [])

        edited = plan_merge(
            '[mcp_servers.private]\ntoken = "token-personal"\n',
            '[mcp_servers.private]\ntoken = "token-new"\n',
            acknowledged=base,
        )
        self.assertEqual(
            edited.conflicts, [{"path": ["mcp_servers", "private", "token"]}]
        )
        self.assertIn('token = "token-personal"', edited.config_text)

    def test_adoption_is_conservative_and_notices_only_profile_keys(self):
        local = (
            'model = "gpt-6-astra"\napproval_policy = "never"\n'
            'sandbox_mode = "danger-full-access"\nlocal_only = "stay"\n'
        )
        incoming = (
            'model = "gpt-5.6-sol"\napproval_policy = "on-request"\n'
            'sandbox_mode = "workspace-write"\nnew_default = true\n'
        )
        plan = plan_merge(local, incoming, adoption=True)
        self.assertEqual(plan.conflicts, [])
        self.assertEqual(
            plan.adoption_notices,
            [
                {"path": ["approval_policy"]},
                {"path": ["sandbox_mode"]},
            ],
        )
        self.assertIn('model = "gpt-6-astra"', plan.config_text)
        self.assertIn('approval_policy = "never"', plan.config_text)
        self.assertIn('sandbox_mode = "danger-full-access"', plan.config_text)
        self.assertIn('local_only = "stay"', plan.config_text)
        self.assertIn("new_default = true", plan.config_text)

        choose_profile = plan_merge(
            local,
            incoming,
            adoption=True,
            decisions={
                ("approval_policy",): "blueprint",
                ("sandbox_mode",): "local",
            },
        )
        self.assertIn('approval_policy = "on-request"', choose_profile.config_text)
        self.assertIn('sandbox_mode = "danger-full-access"', choose_profile.config_text)

    def test_missing_config_does_not_seed_blueprint_projects(self):
        incoming = (
            'model = "gpt-5.6-sol"\n\n'
            '[projects."/blueprint"]\ntrust_level = "trusted"\n'
        )
        plan = plan_merge(None, incoming)
        self.assertIn('model = "gpt-5.6-sol"', plan.config_text)
        self.assertNotIn("projects", plan.config_text)

    def test_semantic_noop_preserves_original_bytes_and_quoted_dot_path(self):
        original = '# keep this comment\n"a.b" = 1  # and this one\n'
        base = self.baseline('"a.b" = 1\n').acknowledged
        noop = plan_merge(original, '"a.b" = 1\n', acknowledged=base)
        self.assertFalse(noop.config_changed)
        self.assertEqual(noop.config_text, original)

        changed = plan_merge(original, '"a.b" = 2\n', acknowledged=base)
        self.assertEqual(changed.conflicts, [])
        self.assertIn({"path": ["a.b"], "operation": "replace"}, changed.changes)

    def test_acknowledged_removal_keeps_a_missing_sentinel(self):
        base = self.baseline("x = 1\n").acknowledged
        conflict = plan_merge("x = 2\n", "", acknowledged=base)
        self.assertEqual(conflict.conflicts, [{"path": ["x"]}])

        keep = plan_merge(
            "x = 2\n",
            "",
            acknowledged=base,
            decisions={("x",): "local"},
        )
        self.assertEqual(keep.acknowledged["children"]["x"]["type"], "missing")
        repeat = plan_merge("x = 2\n", "", acknowledged=keep.acknowledged)
        self.assertEqual(repeat.conflicts, [])
        later = plan_merge("x = 2\n", "x = 3\n", acknowledged=keep.acknowledged)
        self.assertEqual(later.conflicts, [{"path": ["x"]}])

    def test_pure_planner_rejects_invalid_acknowledgment_tree(self):
        invalid = {
            "type": "table",
            "fingerprint": "sha256:" + "0" * 64,
            "children": {},
        }
        plan = plan_merge("x = 9\n", "x = 1\n", acknowledged=invalid)
        self.assertEqual(plan.error, {"code": "invalid_receipt"})
        self.assertFalse(plan.config_changed)
        self.assertEqual(plan.config_text, "x = 9\n")


class CliFixture(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.clone = self.root / "clone"
        self._git("init", "--bare", str(self.remote), cwd=self.root)
        self._git("init", str(self.seed), cwd=self.root)
        self._git("config", "user.name", "Fixture", cwd=self.seed)
        self._git("config", "user.email", "fixture@example.invalid", cwd=self.seed)
        self.template_rel = Path("configs/codex/config.toml")
        template = self.seed / self.template_rel
        template.parent.mkdir(parents=True)
        template.write_text('x = "{{ VALUE }}"\n', encoding="utf-8")
        self._git("add", str(self.template_rel), cwd=self.seed)
        self._git("commit", "-m", "initial", cwd=self.seed)
        self._git("branch", "-M", "main", cwd=self.seed)
        self._git("remote", "add", "origin", str(self.remote), cwd=self.seed)
        self._git("push", "-u", "origin", "main", cwd=self.seed)
        self._git(
            "symbolic-ref", "HEAD", "refs/heads/main", cwd=self.remote, git_dir=True
        )
        self._git("clone", str(self.remote), str(self.clone), cwd=self.root)
        self._git("config", "user.name", "Fixture", cwd=self.clone)
        self._git("config", "user.email", "fixture@example.invalid", cwd=self.clone)

        self.dest = self.root / "home/.codex/config.toml"
        self.dest.parent.mkdir(parents=True)
        self.source = self.root / "rendered.toml"
        self.source.write_text("x = 1\n", encoding="utf-8")

    def tearDown(self):
        self.temporary.cleanup()

    def _git(self, *args, cwd, git_dir=False):
        command = ["git"]
        if git_dir:
            command.extend(["--git-dir", str(cwd)])
            cwd = self.root
        command.extend(args)
        return subprocess.run(
            command,
            cwd=str(cwd),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    @property
    def template(self):
        return self.clone / self.template_rel

    @property
    def state_path(self):
        return self.dest.parent / ".aicoding-sync/config-state.json"

    def request(self, action="plan", **overrides):
        values = {
            "action": action,
            "source": self.source,
            "template": self.template,
            "dest": self.dest,
            "clone": self.clone,
            "profile": "host",
            "local": False,
            "tracked": False,
            "allow_adopt": False,
            "expected": None,
            "decisions": [],
        }
        values.update(overrides)
        return Request(**values)

    def cli(self, action="plan", *extra):
        command = [
            sys.executable,
            str(LIB / "codex-merge.py"),
            action,
            "--source",
            str(self.source),
            "--template",
            str(self.template),
            "--dest",
            str(self.dest),
            "--clone",
            str(self.clone),
            "--profile",
            "host",
            *extra,
        ]
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        completed = subprocess.run(
            command,
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError:
            self.fail(
                "CLI did not return JSON: status={} stdout={!r} stderr={!r}".format(
                    completed.returncode, completed.stdout, completed.stderr
                )
            )
        return completed, payload

    def initial_apply(self, *extra):
        completed, payload = self.cli("apply", *extra)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(payload["applied"])
        return payload

    def commit_template(self, text, message="update"):
        self.template.write_text(text, encoding="utf-8")
        self._git("add", str(self.template_rel), cwd=self.clone)
        self._git("commit", "-m", message, cwd=self.clone)
        self._git("push", "origin", "main", cwd=self.clone)
        return self._git("rev-parse", "HEAD", cwd=self.clone)


class CliBehaviorTests(CliFixture):
    def test_missing_vendored_runtime_is_a_fixed_error_and_preserves_config(self):
        isolated = self.root / "isolated-lib"
        isolated.mkdir()
        for name in ("codex-merge.py", "codex_merge.py", "codex_merge_state.py"):
            shutil.copy2(LIB / name, isolated / name)
        self.dest.write_text("x = 9\n", encoding="utf-8")
        before = self.dest.read_bytes()
        command = [
            sys.executable,
            "-S",
            str(isolated / "codex-merge.py"),
            "apply",
            "--source",
            str(self.source),
            "--template",
            str(self.template),
            "--dest",
            str(self.dest),
            "--clone",
            str(self.clone),
            "--profile",
            "host",
            "--allow-adopt",
        ]
        completed = subprocess.run(
            command,
            cwd=str(self.root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1"),
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(
            json.loads(completed.stdout)["error"], {"code": "runtime_unavailable"}
        )
        self.assertEqual(self.dest.read_bytes(), before)
        self.assertFalse(self.state_path.parent.exists())

    def test_plan_is_read_only_and_apply_creates_private_config_and_receipt(self):
        completed, plan = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(
            set(plan),
            {
                "adoption_notices",
                "changes",
                "config_changed",
                "conflicts",
                "error",
                "state_changed",
                "token",
                "unmanaged",
            },
        )
        self.assertTrue(plan["config_changed"])
        self.assertTrue(plan["state_changed"])
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.state_path.parent.exists())

        applied = self.initial_apply()
        self.assertEqual(set(applied), set(plan) | {"applied"})
        self.assertEqual(self.dest.read_text(encoding="utf-8"), "x = 1\n")
        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["version"], 1)
        self.assertEqual(receipt["provenance"]["source_kind"], "tracking")
        self.assertEqual(receipt["provenance"]["profile"], "host")
        self.assertEqual(receipt["provenance"]["revision"], self._git("rev-parse", "HEAD", cwd=self.clone))
        self.assertNotIn("x = 1", self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(self.state_path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.state_path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o600)
        self.assertEqual(
            sorted(path.name for path in self.state_path.parent.iterdir()),
            ["config-state.json", "lock"],
        )

    def test_untracked_config_is_refused_until_explicit_adoption(self):
        self.dest.write_text("x = 9\n", encoding="utf-8")
        before = self.dest.read_bytes()

        completed, plan = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(plan["unmanaged"])
        self.assertFalse(plan["config_changed"])
        self.assertFalse(plan["state_changed"])
        completed, applied = self.cli("apply")
        self.assertEqual(completed.returncode, 0)
        self.assertFalse(applied["applied"])
        self.assertEqual(self.dest.read_bytes(), before)
        self.assertFalse(self.state_path.parent.exists())

        adopted = self.initial_apply("--allow-adopt")
        self.assertFalse(adopted["unmanaged"])
        self.assertEqual(self.dest.read_bytes(), before)
        self.assertTrue(self.state_path.exists())

    def test_legacy_tracked_flag_conservatively_adopts(self):
        self.dest.write_text("x = 9\nlocal_only = true\n", encoding="utf-8")
        applied = self.initial_apply("--tracked")
        self.assertFalse(applied["unmanaged"])
        self.assertIn("x = 9", self.dest.read_text(encoding="utf-8"))
        self.assertIn("local_only = true", self.dest.read_text(encoding="utf-8"))

    def test_conflict_decisions_require_matching_preview_and_known_path(self):
        self.initial_apply()
        self.dest.write_text("x = 2\n", encoding="utf-8")
        self.source.write_text("x = 3\n", encoding="utf-8")
        completed, plan = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(plan["conflicts"], [{"path": ["x"]}])
        decisions = self.root / "decisions.json"
        decisions.write_text(
            json.dumps([{"path": ["x"], "choice": "local"}]), encoding="utf-8"
        )

        completed, missing = self.cli("apply", "--decisions", str(decisions))
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(missing["error"], {"code": "expected_token_required"})
        self.assertEqual(self.dest.read_text(encoding="utf-8"), "x = 2\n")

        completed, stale = self.cli(
            "apply", "--expected", "not-the-token", "--decisions", str(decisions)
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(stale["error"], {"code": "stale_plan"})

        decisions.write_text(
            json.dumps([{"path": ["other"], "choice": "local"}]), encoding="utf-8"
        )
        completed, unknown = self.cli(
            "apply", "--expected", plan["token"], "--decisions", str(decisions)
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(unknown["error"], {"code": "unknown_decision_path"})

        decisions.write_text(
            json.dumps([{"path": ["x"], "choice": "local"}]), encoding="utf-8"
        )
        completed, kept = self.cli(
            "apply", "--expected", plan["token"], "--decisions", str(decisions)
        )
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(kept["applied"])
        self.assertEqual(kept["conflicts"], [])
        self.assertFalse(kept["config_changed"])
        self.assertTrue(kept["state_changed"])

        completed, repeat = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(repeat["conflicts"], [])
        self.source.write_text("x = 4\n", encoding="utf-8")
        completed, later = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(later["conflicts"], [{"path": ["x"]}])

    def test_expected_token_detects_config_and_receipt_changes(self):
        self.initial_apply()
        self.source.write_text("x = 2\n", encoding="utf-8")
        _, plan = self.cli("plan")
        self.dest.write_text("x = 7\n", encoding="utf-8")
        completed, stale = self.cli("apply", "--expected", plan["token"])
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(stale["error"], {"code": "stale_plan"})

        self.dest.write_text("x = 1\n", encoding="utf-8")
        _, plan = self.cli("plan")
        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        receipt["provenance"]["template_sha256"] = "sha256:" + "a" * 64
        self.state_path.write_text(json.dumps(receipt), encoding="utf-8")
        completed, stale = self.cli("apply", "--expected", plan["token"])
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(stale["error"], {"code": "stale_plan"})

    def test_noop_apply_does_not_replace_config(self):
        self.initial_apply()
        before = self.dest.stat()
        time.sleep(0.01)
        completed, applied = self.cli("apply")
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(applied["applied"])
        self.assertFalse(applied["config_changed"])
        self.assertFalse(applied["state_changed"])
        after = self.dest.stat()
        self.assertEqual((after.st_ino, after.st_mtime_ns), (before.st_ino, before.st_mtime_ns))

    def test_invalid_inputs_and_receipts_are_value_safe_and_write_nothing(self):
        secret = "credential-super-secret"
        self.source.write_text('token = "{}"\nbroken = [\n'.format(secret), encoding="utf-8")
        completed, payload = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "invalid_source_toml"})
        self.assertNotIn(secret, completed.stdout + completed.stderr)
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.state_path.parent.exists())

        self.source.write_text("x = 1\n", encoding="utf-8")
        self.initial_apply()
        before = self.dest.read_bytes()
        self.state_path.write_text('{"leak":"' + secret, encoding="utf-8")
        completed, payload = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "invalid_receipt"})
        self.assertNotIn(secret, completed.stdout + completed.stderr)
        self.assertEqual(self.dest.read_bytes(), before)

    def test_receipt_version_requires_an_integer_one(self):
        self.initial_apply()
        valid = json.loads(self.state_path.read_text(encoding="utf-8"))
        before = self.dest.read_bytes()

        valid["version"] = True
        self.state_path.write_text(json.dumps(valid), encoding="utf-8")
        completed, invalid = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(invalid["error"], {"code": "invalid_receipt"})
        self.assertEqual(self.dest.read_bytes(), before)

        valid["version"] = 2
        self.state_path.write_text(json.dumps(valid), encoding="utf-8")
        completed, unsupported = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(
            unsupported["error"], {"code": "unsupported_receipt_version"}
        )
        self.assertEqual(self.dest.read_bytes(), before)

    def test_malformed_decisions_do_not_echo_their_contents(self):
        self.initial_apply()
        secret = "decision-credential-value"
        decisions = self.root / "decisions.json"
        decisions.write_text('{"secret":"' + secret, encoding="utf-8")
        completed, payload = self.cli("apply", "--decisions", str(decisions))
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "invalid_decisions"})
        self.assertNotIn(secret, completed.stdout + completed.stderr)

    def test_profile_adoption_decision_is_token_bound_and_one_time(self):
        self.dest.write_text(
            'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n',
            encoding="utf-8",
        )
        self.source.write_text(
            'approval_policy = "on-request"\nsandbox_mode = "workspace-write"\n',
            encoding="utf-8",
        )
        completed, plan = self.cli("plan", "--allow-adopt")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(
            plan["adoption_notices"],
            [
                {"path": ["approval_policy"]},
                {"path": ["sandbox_mode"]},
            ],
        )
        decisions = self.root / "decisions.json"
        decisions.write_text(
            json.dumps(
                [
                    {"path": ["approval_policy"], "choice": "blueprint"},
                    {"path": ["sandbox_mode"], "choice": "local"},
                ]
            ),
            encoding="utf-8",
        )
        completed, applied = self.cli(
            "apply",
            "--allow-adopt",
            "--expected",
            plan["token"],
            "--decisions",
            str(decisions),
        )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(applied["adoption_notices"], [])
        self.assertIn('approval_policy = "on-request"', self.dest.read_text(encoding="utf-8"))
        self.assertIn('sandbox_mode = "danger-full-access"', self.dest.read_text(encoding="utf-8"))
        completed, repeat = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(repeat["adoption_notices"], [])

    def test_valid_receipt_establishes_management_without_tracked_flag(self):
        self.initial_apply()
        self.source.write_text("x = 2\n", encoding="utf-8")
        completed, payload = self.cli("apply")
        self.assertEqual(completed.returncode, 0)
        self.assertFalse(payload["unmanaged"])
        self.assertEqual(self.dest.read_text(encoding="utf-8"), "x = 2\n")

    def test_missing_managed_config_restores_current_blueprint_after_receipt_validation(self):
        self.source.write_text(
            'model = "gpt-5.6-sol"\nx = 1\n\n'
            '[projects."/blueprint"]\ntrust_level = "trusted"\n',
            encoding="utf-8",
        )
        self.initial_apply()
        valid_receipt = self.state_path.read_bytes()
        self.dest.unlink()
        self.source.write_text(
            'model = "gpt-5.6-sol"\nx = 2\n\n'
            '[projects."/blueprint"]\ntrust_level = "trusted"\n',
            encoding="utf-8",
        )

        completed, plan = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(plan["conflicts"], [])
        self.assertTrue(plan["config_changed"])
        restored = self.initial_apply()
        self.assertTrue(restored["config_changed"])
        self.assertIn('model = "gpt-5.6-sol"', self.dest.read_text(encoding="utf-8"))
        self.assertIn("x = 2", self.dest.read_text(encoding="utf-8"))
        self.assertNotIn("projects", self.dest.read_text(encoding="utf-8"))

        self.dest.unlink()
        self.state_path.write_text("not-json", encoding="utf-8")
        completed, invalid = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(invalid["error"], {"code": "invalid_receipt"})
        self.assertFalse(self.dest.exists())

        self.state_path.write_bytes(valid_receipt)
        response, status = execute(self.request("apply", profile="container"))
        self.assertNotEqual(status, 0)
        self.assertEqual(response["error"]["code"], "profile_mismatch")
        self.assertFalse(self.dest.exists())

        receipt = json.loads(valid_receipt)
        receipt["provenance"]["revision"] = "0" * 40
        self.state_path.write_text(json.dumps(receipt), encoding="utf-8")
        completed, stale = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(stale["error"], {"code": "revision_unavailable"})
        self.assertFalse(self.dest.exists())

    def test_profile_mismatch_and_unavailable_revision_preserve_files(self):
        self.initial_apply()
        before = self.dest.read_bytes()
        command_extra = ["--profile", "container"]
        # Replace the helper's final profile using a direct request to avoid
        # duplicate argparse options obscuring the contract under test.
        response, status = execute(self.request("apply", profile="container"))
        self.assertNotEqual(status, 0)
        self.assertEqual(
            response["error"],
            {
                "code": "profile_mismatch",
                "incoming_profile": "container",
                "recorded_profile": "host",
            },
        )
        self.assertEqual(self.dest.read_bytes(), before)

        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        receipt["provenance"]["revision"] = "0" * 40
        self.state_path.write_text(json.dumps(receipt), encoding="utf-8")
        completed, payload = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "revision_unavailable"})
        self.assertEqual(self.dest.read_bytes(), before)

    def test_tracking_rejects_older_revision_and_accepts_newer(self):
        old_revision = self._git("rev-parse", "HEAD", cwd=self.clone)
        self.initial_apply()
        new_revision = self.commit_template('x = "{{ NEW_VALUE }}"\n')
        self.source.write_text("x = 2\n", encoding="utf-8")
        completed, payload = self.cli("apply")
        self.assertEqual(completed.returncode, 0)
        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["provenance"]["revision"], new_revision)

        self._git("checkout", "--detach", old_revision, cwd=self.clone)
        before = self.dest.read_bytes()
        completed, payload = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "older_revision"})
        self.assertEqual(self.dest.read_bytes(), before)

    def test_tracking_rejects_divergent_revision(self):
        original = self._git("rev-parse", "HEAD", cwd=self.clone)
        self.initial_apply()
        self.commit_template('x = "{{ MAIN_TWO }}"\n', "main two")
        self.source.write_text("x = 2\n", encoding="utf-8")
        self.initial_apply()

        self._git("checkout", "-b", "divergent", original, cwd=self.clone)
        self.template.write_text('x = "{{ DIVERGENT }}"\n', encoding="utf-8")
        self._git("add", str(self.template_rel), cwd=self.clone)
        self._git("commit", "-m", "divergent", cwd=self.clone)
        before = self.dest.read_bytes()
        completed, payload = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "divergent_revision"})
        self.assertEqual(self.dest.read_bytes(), before)

    def test_dirty_tracking_is_refused_but_explicit_local_records_template_digest(self):
        self.template.write_text('x = "{{ DIRTY }}"\n', encoding="utf-8")
        completed, refused = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(refused["error"], {"code": "dirty_tracking_clone"})
        self.assertFalse(self.dest.exists())
        self.assertFalse(self.state_path.parent.exists())

        completed, applied = self.cli("apply", "--local")
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(applied["applied"])
        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["provenance"]["source_kind"], "local")
        self.assertIsNone(receipt["provenance"]["revision"])
        expected_digest = "sha256:" + hashlib.sha256(self.template.read_bytes()).hexdigest()
        self.assertEqual(receipt["provenance"]["template_sha256"], expected_digest)

    def test_different_origin_is_refused_without_printing_origins(self):
        self.initial_apply()
        original_origin = str(self.remote)
        other = self.root / "other.git"
        self._git("init", "--bare", str(other), cwd=self.root)
        self._git("remote", "set-url", "origin", str(other), cwd=self.clone)
        before = self.dest.read_bytes()
        completed, payload = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(payload["error"], {"code": "origin_mismatch"})
        self.assertNotIn(original_origin, completed.stdout + completed.stderr)
        self.assertNotIn(str(other), completed.stdout + completed.stderr)
        self.assertEqual(self.dest.read_bytes(), before)

    def test_origin_credentials_are_removed_before_receipt_storage(self):
        secret = "origin-credential-value"
        self._git(
            "remote",
            "set-url",
            "origin",
            "https://agent:{}@example.invalid/blueprint.git".format(secret),
            cwd=self.clone,
        )
        completed, payload = self.cli("apply")
        self.assertEqual(completed.returncode, 0)
        persisted = self.state_path.read_text(encoding="utf-8")
        self.assertNotIn(secret, completed.stdout + completed.stderr + persisted)
        receipt = json.loads(persisted)
        self.assertEqual(
            receipt["provenance"]["origin"],
            "https://example.invalid/blueprint.git",
        )

    def test_explicit_local_can_return_local_receipt_to_clean_origin_main(self):
        self._git("checkout", "-b", "experiment", cwd=self.clone)
        self.template.write_text('x = "{{ LOCAL }}"\n', encoding="utf-8")
        self._git("add", str(self.template_rel), cwd=self.clone)
        self._git("commit", "-m", "local branch", cwd=self.clone)
        self.initial_apply("--local")
        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["provenance"]["source_kind"], "local")

        completed, refused = self.cli("apply")
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(refused["error"], {"code": "local_to_tracking_refused"})

        self._git("checkout", "main", cwd=self.clone)
        self.source.write_text("x = 1\n", encoding="utf-8")
        completed, restored = self.cli("apply", "--local")
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(restored["applied"])
        receipt = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["provenance"]["source_kind"], "tracking")

    def test_rendered_credentials_never_appear_in_cli_json_or_receipt(self):
        old = "credential-old-value"
        new = "credential-new-value"
        self.source.write_text('[mcp_servers.private]\ntoken = "{}"\n'.format(old), encoding="utf-8")
        completed, first = self.cli("apply")
        self.assertEqual(completed.returncode, 0)
        self.assertNotIn(old, completed.stdout + completed.stderr)
        self.assertNotIn(old, self.state_path.read_text(encoding="utf-8"))

        self.source.write_text('[mcp_servers.private]\ntoken = "{}"\n'.format(new), encoding="utf-8")
        completed, rotated = self.cli("plan")
        self.assertEqual(completed.returncode, 0)
        self.assertNotIn(old, completed.stdout + completed.stderr)
        self.assertNotIn(new, completed.stdout + completed.stderr)
        self.assertEqual(rotated["conflicts"], [])

    def test_apply_waits_for_shared_lock(self):
        self.initial_apply()
        holder = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import fcntl,sys,time; "
                    "f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); "
                    "print('locked',flush=True); time.sleep(0.35)"
                ),
                str(self.state_path.parent / "lock"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        started = time.monotonic()
        completed, payload = self.cli("apply")
        elapsed = time.monotonic() - started
        holder.communicate(timeout=2)
        self.assertEqual(completed.returncode, 0)
        self.assertTrue(payload["applied"])
        self.assertGreaterEqual(elapsed, 0.25)


class ReceiptReplayTests(CliFixture):
    def test_receipt_write_failure_replays_edits_additions_removals_and_parent_changes(self):
        cases = (
            ("x = 1\n", "x = 2\n"),
            ("x = 1\n", "x = 1\ny = 2\n"),
            ("x = 1\ny = 2\n", "x = 1\n"),
            ("x = 1\n", "[x]\ny = 2\n"),
        )
        for index, (baseline, incoming) in enumerate(cases):
            with self.subTest(index=index):
                case_dest = self.root / "case-{}/.codex/config.toml".format(index)
                case_dest.parent.mkdir(parents=True)
                self.source.write_text(baseline, encoding="utf-8")
                first, status = execute(self.request("apply", dest=case_dest))
                self.assertEqual(status, 0)
                self.assertTrue(first["applied"])
                case_state = state_path_for(case_dest)
                old_receipt = case_state.read_bytes()
                self.source.write_text(incoming, encoding="utf-8")

                from codex_merge_state import atomic_write as real_atomic_write

                def fail_receipt(path, *args, **kwargs):
                    if Path(path) == case_state:
                        raise OSError("synthetic receipt failure")
                    return real_atomic_write(path, *args, **kwargs)

                with patch("codex_merge_state.atomic_write", side_effect=fail_receipt):
                    failed, status = execute(self.request("apply", dest=case_dest))
                self.assertNotEqual(status, 0)
                self.assertEqual(failed["error"], {"code": "receipt_write_failed"})
                self.assertEqual(case_state.read_bytes(), old_receipt)
                self.assertEqual(
                    case_dest.read_text(encoding="utf-8").strip(), incoming.strip()
                )

                replay, status = execute(self.request("apply", dest=case_dest))
                self.assertEqual(status, 0)
                self.assertTrue(replay["applied"])
                self.assertFalse(replay["config_changed"])
                self.assertTrue(replay["state_changed"])
                self.assertNotEqual(case_state.read_bytes(), old_receipt)

    def test_config_write_failure_does_not_advance_receipt(self):
        self.source.write_text("x = 1\n", encoding="utf-8")
        self.initial_apply()
        old_config = self.dest.read_bytes()
        old_receipt = self.state_path.read_bytes()
        self.source.write_text("x = 2\n", encoding="utf-8")

        from codex_merge_state import atomic_write as real_atomic_write

        def fail_config(path, *args, **kwargs):
            if Path(path) == self.dest:
                raise OSError("synthetic config failure")
            return real_atomic_write(path, *args, **kwargs)

        with patch("codex_merge_state.atomic_write", side_effect=fail_config):
            failed, status = execute(self.request("apply"))
        self.assertNotEqual(status, 0)
        self.assertEqual(failed["error"], {"code": "config_write_failed"})
        self.assertEqual(self.dest.read_bytes(), old_config)
        self.assertEqual(self.state_path.read_bytes(), old_receipt)


if __name__ == "__main__":
    unittest.main(verbosity=2)
