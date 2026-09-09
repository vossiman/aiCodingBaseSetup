# Workspace activity observations

`dvw-probe` retains schema 1 and adds `activity`. Existing consumers may ignore
this extension. Each value is a nonnegative integer or JSON null (unknown):

- `tmux_sessions`: sessions on the current user's **default** tmux socket.
  The probe explicitly selects `-L default`. If that socket is absent but a
  same-user tmux executable remains, the count is unknown: it may be a custom
  socket. Custom socket sessions are not enumerated; a renamed tmux executable
  is not recognized by this fallback.
  Only recognized no-server / missing-socket responses count as zero.
- `terminals`: distinct nonzero controlling terminal devices belonging to
  current-user processes. Multiple processes on one terminal count once.
  Background Bash and zombie processes do not count.
- `cursor_connections` and `vscode_connections`: established loopback TCP
  connections pairing a current-user DevPod executable with a current-user
  executable under `.cursor-server/` or `.vscode-server/`. Both endpoint socket
  inodes must be owned by those processes. This is a connection count, not a
  count of editor windows or users. Ports are discovered dynamically. A live
  TCP connection owned by a recognized IDE executable whose peer cannot be
  matched to DevPod makes that IDE measurement unknown.

The activity collector reads process ownership, stat, executable symlink and
socket descriptors plus the network namespace's TCP tables. It does not read
command arguments or environment and emits no process paths or socket addresses.
Missing/inaccessible metadata yields null for the affected measurements. Deadline
exhaustion also sets the document's `partial` flag. The existing hard deadline
protects blocking reads; incomplete activity remains null if it fires.

These observations support **dry-run only**, not automatic shutdown. In
particular, custom tmux sockets, other users, IDE executable layouts outside the
recognized directories, and non-DevPod transports are not covered. A zero is
absence within that scope, not proof that a container is safe to stop. Server
processes and bare DevPod processes can survive disconnect and do not themselves
count as active connections. Probe polling processes must not reset an idle timer.

The catalogue must require all activity measurements, known agent data, and a
non-partial document before reporting measured idle. Old probes without activity
are unknown. This collector changes no container lifecycle or provisioning.
