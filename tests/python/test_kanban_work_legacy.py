import unittest

from lib.kanban_work import BridgeError
from lib.kanban_work.legacy import (
    DENIAL,
    looks_like_legacy_complete,
    parse_legacy_complete,
    rewrite_legacy_complete,
)


HANDLE = "11111111-1111-4111-8111-111111111111"


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


class LegacyRewriteTests(unittest.TestCase):
    def test_rewrite_appends_work_handle_to_the_parsed_argv(self):
        argv = rewrite_legacy_complete(
            "kanban-post --done KANBAN-2 --evidence 'pytest: 127 passed' "
            "--reference PR-17 --reference 'commit abc'",
            HANDLE,
        )
        self.assertEqual(argv, [
            "kanban-post", "--done", "KANBAN-2", "--evidence", "pytest: 127 passed",
            "--reference", "PR-17", "--reference", "commit abc",
            "--work-handle", HANDLE,
        ])

    def test_rewrite_accepts_uuid_ticket_and_keeps_literal_single_quoted_dollar(self):
        ticket_id = "44444444-4444-4444-8444-444444444444"
        argv = rewrite_legacy_complete(
            f"kanban-post --done {ticket_id} --evidence 'cost $5'", HANDLE
        )
        self.assertEqual(argv, [
            "kanban-post", "--done", ticket_id, "--evidence", "cost $5",
            "--work-handle", HANDLE,
        ])

    def test_rewrite_denies_commands_that_are_not_a_completion(self):
        for command in (
            "kanban-post --list-tickets",
            "git status --short",
            "kanban-post --done KANBAN-2",
        ):
            with self.subTest(command=command), self.assertRaisesRegex(BridgeError, DENIAL):
                rewrite_legacy_complete(command, HANDLE)

    def test_rewrite_denies_unsafe_or_ungrammatical_completion_text(self):
        for command in (
            "kanban-post --done KANBAN-2 --evidence ok; echo stolen",
            "KANBAN_WORK_HANDLE=x kanban-post --done KANBAN-2 --evidence ok",
            "kanban-post --done KANBAN-2 --evidence ok --work-handle " + HANDLE,
            "kanban-post --done KANBAN-2 --evidence $HOME",
            "kanban-post --done not_a_key --evidence ok",
        ):
            with self.subTest(command=command), self.assertRaises(BridgeError) as raised:
                rewrite_legacy_complete(command, HANDLE)
            self.assertEqual(raised.exception.message, DENIAL)
            self.assertEqual(raised.exception.code, 422)

    def test_looks_like_legacy_complete_detects_candidates_only(self):
        self.assertTrue(looks_like_legacy_complete("kanban-post --done K-1 --evidence ok"))
        self.assertTrue(looks_like_legacy_complete(
            "FOO=1 kanban-post --done K-1 --evidence ok; echo bad"
        ))
        for value in ("kanban-post --done K-1", "kanban-post --list-tickets",
                      "echo kanban-post --done K-1 --evidence ok", None, ["kanban-post"]):
            with self.subTest(value=value):
                self.assertFalse(looks_like_legacy_complete(value))


if __name__ == "__main__":
    unittest.main()
