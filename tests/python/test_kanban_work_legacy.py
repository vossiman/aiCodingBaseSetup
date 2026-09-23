import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

from lib.kanban_work import BridgeError, NativeIdentity, Store, normalize_tool_args
from lib.kanban_work.legacy import parse_legacy_complete, prepare_legacy_complete


HANDLE = "11111111-1111-4111-8111-111111111111"
RUN = "33333333-3333-4333-8333-333333333333"
CLAIM = "backend-claim-ref"
NOW = datetime(2026, 9, 12, tzinfo=UTC)
IDENTITY = NativeIdentity("codex", "thread-7", None, RUN)


class LegacyParserTests(unittest.TestCase):
    def test_exact_grammar_supports_references_spaces_and_literal_single_quoted_dollar(self):
        parsed = parse_legacy_complete(
            "kanban-post --done KANBAN-2 --evidence 'pytest: 127 passed $HOME' "
            "--reference PR-17 --reference 'commit abc'"
        )
        self.assertEqual(parsed.ticket, "KANBAN-2")
        self.assertEqual(parsed.evidence, "pytest: 127 passed $HOME")
        self.assertEqual(parsed.references, ("PR-17", "commit abc"))

    def test_ordinary_legacy_commands_are_outside_completion_translator(self):
        commands = [
            'kanban-post "follow-up" --repo aiCodingBaseSetup',
            "kanban-post --comment AICODINGBASESETUP-2 progress",
            "kanban-post --list-tickets",
            "kanban-post --selftest",
            "FOO=1 kanban-post --list-tickets",
            "git status --short",
        ]
        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(parse_legacy_complete(command))

    def test_every_shell_or_grammar_escape_is_denied_actionably(self):
        invalid = [
            "KANBAN_WORK_HANDLE=x kanban-post --done K-1 --evidence ok",
            "FOO=1 kanban-post --done K-1 --evidence ok",
            "/usr/bin/kanban-post --done K-1 --evidence ok",
            "./kanban-post --done K-1 --evidence ok",
            "kanban-post --evidence ok --done K-1",
            "kanban-post --done K-1 --evidence ''",
            "kanban-post --done K-1 --evidence ok --evidence again",
            "kanban-post --done K-1 --evidence ok --unknown x",
            "kanban-post --done K-1 --evidence ok\necho bad",
            "kanban-post --done K-1 --evidence ok; echo bad",
            "kanban-post --done K-1 --evidence ok | tee x",
            "kanban-post --done K-1 --evidence ok > out",
            "kanban-post --done K-1 --evidence $(id)",
            "kanban-post --done K-1 --evidence `id`",
            "kanban-post --done K-1 --evidence $HOME",
            'kanban-post --done K-1 --evidence "$HOME"',
            "kanban-post --done K-1 --evidence *.txt",
            "kanban-post --done K-1 --evidence foo\\\nbar",
            "kanban-post --done K-1 --evidence ok & echo bad",
            "kanban-post --done K-1 --evidence '(ok)'",
            "kanban-post --done K-1 --evidence ok trailing",
        ]
        for command in invalid:
            with self.subTest(command=command), self.assertRaisesRegex(
                BridgeError, "Use the Kanban MCP complete_ticket tool"
            ):
                parse_legacy_complete(command)


class LegacyTranslatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "kanban.sqlite3")
        self.store.start_execution("codex", "thread-7", None, RUN, HANDLE, "/tmp/repo", True, now=NOW)
        self.store.record_bound(HANDLE, "backend-session-ref", "kanban", "worker")
        self.store.set_claim(HANDLE, CLAIM, "KANBAN-2")

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def test_exact_completion_mints_native_owned_permit_and_safe_argv(self):
        prepared = prepare_legacy_complete(
            IDENTITY, "tool-9",
            "kanban-post --done KANBAN-2 --evidence 'pytest: 127 passed' --reference PR-17",
            store=self.store, now=NOW,
        )
        self.assertEqual(prepared.handle, HANDLE)
        self.assertEqual(prepared.args, {
            "handle": HANDLE, "claim_id": CLAIM,
            "evidence": "pytest: 127 passed", "references": ["PR-17"],
            "operation_id": None,
        })
        self.assertEqual(prepared.rewritten_argv[-2:], ["--work-handle", HANDLE])
        self.assertTrue(self.store.has_permit(
            HANDLE, "complete_ticket", normalize_tool_args("complete_ticket", prepared.args)
        ))

    def test_uuid_completion_matches_lookup_identity_and_mints_permit(self):
        ticket_id = "44444444-4444-4444-8444-444444444444"
        self.store.set_claim(HANDLE, CLAIM, "KANBAN-2", ticket_id=ticket_id)

        claim = self.store.lookup(HANDLE)["active_claim"]
        self.assertEqual(claim, {
            "id": CLAIM, "ticket": "KANBAN-2", "ticket_id": ticket_id,
        })
        prepared = prepare_legacy_complete(
            IDENTITY, "tool-uuid",
            f"kanban-post --done {ticket_id} --evidence 'pytest: 127 passed'",
            store=self.store, now=NOW,
        )
        self.assertTrue(self.store.has_permit(
            HANDLE, "complete_ticket", normalize_tool_args("complete_ticket", prepared.args)
        ))

    def test_missing_identity_claim_ticket_mismatch_and_peer_are_denied_without_permit(self):
        cases = [
            (NativeIdentity("codex", "missing", None, RUN), "KANBAN-2"),
            (IDENTITY, "KANBAN-3"),
            (NativeIdentity("codex", "thread-7", "peer", RUN), "KANBAN-2"),
        ]
        for i, (identity, ticket) in enumerate(cases):
            with self.subTest(identity=identity, ticket=ticket), self.assertRaises(BridgeError):
                prepare_legacy_complete(identity, f"tool-{i}",
                    f"kanban-post --done {ticket} --evidence ok", store=self.store, now=NOW)
        self.assertFalse(self.store.has_any_permit())

    def test_missing_current_claim_is_denied_without_permit(self):
        self.store.refresh_authoritative(HANDLE, {
            "id": "backend-session-ref", "harness": "codex", "native_session_id": "thread-7",
            "subagent_id": None, "run_generation": RUN, "label": "worker", "repo": "kanban",
            "lifecycle_capable": True, "ended_at": None, "claims": [],
        }, None)
        with self.assertRaisesRegex(BridgeError, "no current claim"):
            prepare_legacy_complete(IDENTITY, "tool-no-claim",
                                    "kanban-post --done KANBAN-2 --evidence ok",
                                    store=self.store, now=NOW)
        self.assertFalse(self.store.has_any_permit())

    def test_compound_completion_is_denied_before_identity_resolution(self):
        with self.assertRaisesRegex(BridgeError, "Use the Kanban MCP complete_ticket tool"):
            prepare_legacy_complete(
                NativeIdentity("codex", "missing", None, RUN), "tool-10",
                "kanban-post --done KANBAN-2 --evidence ok; echo stolen",
                store=self.store, now=NOW,
            )
        self.assertFalse(self.store.has_any_permit())


if __name__ == "__main__":
    unittest.main()
