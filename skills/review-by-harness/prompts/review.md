Review this pull request's diff for correctness bugs, security problems, and
changes that are simply wrong about how the surrounding code behaves.

Report only findings you can ground in the code. For each one give:

- a severity (P1 blocking / P2 should-fix / P3 nit),
- the exact file and line,
- what breaks, concretely — the input or command that triggers it,
- the specific fix.

Verify claims against the actual source before making them. A confident,
wrong finding costs more than a missed one. Say so plainly if the diff looks
correct.
