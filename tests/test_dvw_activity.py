import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

P = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'bin/dvw-probe'))

class ActivityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.proc = Path(self.tmp.name)
        (self.proc / 'net').mkdir()
        for name in ('tcp', 'tcp6'):
            (self.proc / 'net' / name).write_text('  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n')

    def process(self, pid, exe='/usr/bin/bash', tty=0, sockets=()):
        d = self.proc / str(pid)
        d.mkdir()
        (d / 'stat').write_text(f'{pid} (name with spaces) S 1 1 1 {tty} 0 0')
        (d / 'exe').symlink_to(exe)
        (d / 'fd').mkdir()
        for n, inode in enumerate(sockets):
            (d / 'fd' / str(n)).symlink_to(f'socket:[{inode}]')
        return d

    def collect(self):
        fn = P.get('collect_activity')
        self.assertIsNotNone(fn, 'activity collector must exist')
        with patch.dict(fn.__globals__, {'_run': lambda *a: subprocess.CompletedProcess([], 1, '', 'no server running on /tmp/tmux-1000/default\n')}):
            return fn(str(self.proc), P['Budget'](3))

    def test_custom_tmux_server_prevents_false_zero(self):
        self.process(1, '/usr/bin/tmux')
        self.assertIsNone(self.collect()['tmux_sessions'])

    def test_unreadable_agent_metadata_marks_partial(self):
        self.process(1)
        (self.proc / 'stat').write_text('btime 1\n')
        budget = P['Budget'](3)
        P['collect_agents'](str(self.proc), budget)
        self.assertTrue(budget.partial)

    def test_baseline_and_background_bash(self):
        self.process(1)
        self.assertEqual(self.collect(), dict(tmux_sessions=0, terminals=0, cursor_connections=0, vscode_connections=0))

    def test_terminal_open_then_closed(self):
        d = self.process(1, tty=34816)
        self.process(2, tty=34816)
        self.assertEqual(self.collect()['terminals'], 1)
        (d / 'stat').write_text('1 (bash) S 1 1 1 0 0 0')
        (self.proc / '2' / 'stat').write_text('2 (bash) S 1 1 1 0 0 0')
        self.assertEqual(self.collect()['terminals'], 0)

    def test_cursor_connection_and_leftover_server(self):
        self.process(1, '/tmp/devpod', sockets=(101,))
        self.process(2, '/home/codespace/.cursor-server/bin/build/node', sockets=(102,))
        tcp = self.proc / 'net' / 'tcp'
        header = tcp.read_text()
        tcp.write_text(header + '0: 0100007F:AAAA 0100007F:BBBB 01 0:0 00:0 0 1000 0 101\n1: 0100007F:BBBB 0100007F:AAAA 01 0:0 00:0 0 1000 0 102\n')
        self.assertEqual(self.collect()['cursor_connections'], 1)
        tcp.write_text(header)
        self.assertEqual(self.collect()['cursor_connections'], 0)

    def test_missing_metadata_is_unknown(self):
        d = self.process(1)
        real_readlink = os.readlink

        def denied(path, *a, **kw):
            if str(path).endswith('/exe'):
                raise PermissionError(13, 'Permission denied')
            return real_readlink(path, *a, **kw)

        with patch.object(os, 'readlink', denied):
            self.assertIsNone(self.collect()['cursor_connections'])
        (d / 'stat').write_text('malformed')
        self.assertIsNone(self.collect()['terminals'])

    def test_a_process_with_no_exe_is_skipped_not_distrusted(self):
        """A zombie keeps /proc/<pid> but has no exe, so an existence check
        cannot tell it from a live process. It can never be an IDE or devpod
        process either way, so skip it instead of nulling the whole sample.
        """
        d = self.process(1)
        (d / 'exe').unlink()
        self.assertEqual(self.collect(), dict(tmux_sessions=0, terminals=0,
                                              cursor_connections=0,
                                              vscode_connections=0))

    def test_malformed_tcp_address_is_unknown(self):
        tcp = self.proc / 'net' / 'tcp'
        tcp.write_text(tcp.read_text() + '0: broken 0100007F:AAAA 01 0:0 00:0 0 1000 0 101\n')
        self.assertIsNone(self.collect()['cursor_connections'])

    def test_missing_tcp_is_unknown(self):
        (self.proc / 'net' / 'tcp').unlink()
        self.assertIsNone(self.collect()['cursor_connections'])

    def test_unsupported_live_ide_transport_is_unknown(self):
        self.process(1, '/home/codespace/.cursor-server/bin/build/node', sockets=(102,))
        tcp = self.proc / 'net' / 'tcp'
        tcp.write_text(tcp.read_text() + '0: 0100007F:AAAA 0100007F:BBBB 01 0:0 00:0 0 1000 0 102\n')
        self.assertIsNone(self.collect()['cursor_connections'])
        self.assertEqual(self.collect()['vscode_connections'], 0)

    def test_vscode_and_non_ide_traffic(self):
        self.process(1, '/tmp/devpod', sockets=(101,))
        self.process(2, '/home/codespace/.vscode-server/bin/build/node', sockets=(102,))
        tcp = self.proc / 'net' / 'tcp'
        tcp.write_text(tcp.read_text() + '0: 0100007F:AAAA 0100007F:BBBB 01 0:0 00:0 0 1000 0 101\n1: 0100007F:BBBB 0100007F:AAAA 01 0:0 00:0 0 1000 0 102\n')
        self.assertEqual(self.collect()['vscode_connections'], 1)
        self.assertEqual(self.collect()['cursor_connections'], 0)

    def test_tmux_permission_failure_is_unknown(self):
        fn = P['collect_activity']
        with patch.dict(fn.__globals__, {'_run': lambda *a: subprocess.CompletedProcess([], 1, '', 'permission denied')}):
            self.assertIsNone(fn(str(self.proc), P['Budget'](3))['tmux_sessions'])

    def test_a_pid_that_exits_mid_walk_does_not_blank_the_sample(self):
        """The whole reason dvw idle countdowns kept restarting.

        A pid listed by listdir and gone by the time it is stat'd is routine
        on a busy workspace. Treating it as a measurement failure nulled all
        four signals while leaving partial False, so the catalog saw a
        complete report it could not use and reset the idle countdown.
        """
        self.process(1)
        fn = P['collect_activity']
        budget = P['Budget'](3)
        real_listdir = os.listdir

        def listing(path, *a, **kw):
            entries = real_listdir(path, *a, **kw)
            if str(path) == str(self.proc):
                entries = entries + ['999']  # exited between listdir and stat
            return entries

        with patch.dict(fn.__globals__, {'_run': lambda *a: subprocess.CompletedProcess([], 1, '', 'no server running on /tmp/tmux-1000/default\n')}):
            with patch.object(os, 'listdir', listing):
                result = fn(str(self.proc), budget)
        self.assertEqual(result, dict(tmux_sessions=0, terminals=0,
                                      cursor_connections=0, vscode_connections=0))
        self.assertFalse(budget.partial)

    def test_budget_exhaustion_is_unknown(self):
        fn = P['collect_activity']
        with patch.dict(fn.__globals__, {'_run': lambda *a: subprocess.CompletedProcess([], 0, '$1\n', '')}):
            result = fn(str(self.proc), P['Budget'](-1))
            self.assertIsNone(result['terminals'])
            self.assertIsNone(result['cursor_connections'])

if __name__ == '__main__':
    unittest.main()
