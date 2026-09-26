#!/usr/bin/env python3
"""Coverage checks for lib/status-reasons.json.

  status_reasons.py static [ROOT]      every literal reason in lib/ and bin/ has an entry
  status_reasons.py stale [ROOT]       every entry is still produced somewhere
  status_reasons.py audit FILE [ROOT]  every reason recorded during a test run has an entry
  status_reasons.py list [ROOT]        print the literal reasons the scanner finds
"""
import fnmatch
import json
import re
import sys
from pathlib import Path

CODE = r"[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[a-z]+"
# The recorder itself: aicoding_result_record COMPONENT STATE TARGET REASON.
# _sched_note_reason REASON stages the scheduled provisioning reason in a file.
BASE_RECORDERS = {"aicoding_result_record": 4, "_sched_note_reason": 1}
ASSIGNED = [
    re.compile(r"(?<![\w$])\w*reason=(['\"]?)(" + CODE + r")\1(?=[\s;)|&]|$)"),
    re.compile(r"\$\{\w*reason\w*(?:\[[^]]*\])?:-()(" + CODE + r")\}"),
    # compatibility checks print the reason and return nonzero
    re.compile(r"\becho\s+()(" + CODE + r")\s*;\s*return\s+[1-9]"),
]
FUNCTION = re.compile(r"^([A-Za-z_][\w-]*)\s*\(\)\s*\{", re.M)


def source_files(root):
    for base in ("lib", "bin"):
        for path in sorted((root / base).rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                try:
                    yield path, path.read_text()
                except UnicodeDecodeError:
                    continue


def literal(token):
    token = token.strip("'\"")
    return token if re.fullmatch(CODE, token) else None


def joined(text):
    return re.sub(r"\\\n\s*", " ", text)


def call_args(line, name):
    """Yield the whitespace-split argument list of each call to `name`."""
    for m in re.finditer(r"(?<![\w-])" + re.escape(name) + r"(?=\s)", line):
        yield line[m.end():].split()


def functions(text):
    """Yield (name, body) for top-level shell functions (closing brace in column 0)."""
    for m in FUNCTION.finditer(text):
        end = re.search(r"^\}", text[m.end():], re.M)
        yield m.group(1), text[m.end():m.end() + end.start()] if end else ""


def recorders(root):
    """Map every function that records a reason to that reason's argument position.

    A wrapper forwards its own positional argument ("$N") or all of them ("$@")
    into a known recorder; iterate until no new wrapper appears.
    """
    known = dict(BASE_RECORDERS)
    bodies = []
    for _, text in source_files(root):
        for name, body in functions(text):
            body = joined(body)
            # `local reason=$2` makes "$reason" an alias for positional 2.
            aliases = {a: int(n) for a, n in re.findall(r"\b(\w+)=\$\{?([0-9])\}?(?=[\s;]|$)", body, re.M)}
            bodies.append((name, body, aliases))
    changed = True
    while changed:
        changed = False
        for name, body, aliases in bodies:
            if name in known:
                continue
            for recorder, position in list(known.items()):
                for line in body.splitlines():
                    for args in call_args(line, recorder):
                        if len(args) >= position:
                            token = args[position - 1].strip("'\";")
                            m = re.fullmatch(r"\$\{?([0-9]|\w+)\}?", token)
                            if m and m.group(1).isdigit():
                                known[name] = int(m.group(1))
                            elif m and m.group(1) in aliases:
                                known[name] = aliases[m.group(1)]
                        if args and args[0].strip("'\"") == "$@":
                            known[name] = position
                    if name in known:
                        break
                if name in known:
                    changed = True
                    break
    return known


def scan(root):
    """Return {reason: sorted source files} for every literal reason."""
    known = recorders(root)
    found = {}
    for path, text in source_files(root):
        for line in joined(text).splitlines():
            if line.lstrip().startswith("#"):
                continue
            line = re.sub(r"command -v \S+", "", line)
            hits = []
            for recorder, position in known.items():
                for args in call_args(line, recorder):
                    if len(args) >= position:
                        hits.append(literal(args[position - 1].rstrip(";")))
            for rx in ASSIGNED:
                hits.extend(m.group(2) for m in rx.finditer(line))
            for reason in filter(None, hits):
                found.setdefault(reason, set()).add(str(path.relative_to(root)))
    return {k: sorted(v) for k, v in found.items()}


def catalog(root):
    return json.loads((root / "lib/status-reasons.json").read_text())


def covered(reason, cat):
    if reason in cat["reasons"]:
        return True
    return any(fnmatch.fnmatchcase(reason, p) for p in cat.get("patterns", {}))


def check_static(root):
    cat = catalog(root)
    return [f"{r} (from {', '.join(files)})" for r, files in sorted(scan(root).items()) if not covered(r, cat)]


def check_stale(root):
    cat = catalog(root)
    found = scan(root)
    corpus = "\n".join(text for _, text in source_files(root))
    stale = [r for r in cat["reasons"] if r not in found]
    for pattern, entry in cat.get("patterns", {}).items():
        marker = entry.get("source_marker", "")
        if not marker or marker not in corpus:
            stale.append(pattern)
    return sorted(stale)


def check_audit(path, root):
    cat = catalog(root)
    seen = set()
    try:
        lines = Path(path).read_text().splitlines()
    except FileNotFoundError:
        return []
    for line in lines:
        reason = line.strip()
        if reason and not covered(reason, cat):
            seen.add(reason)
    return sorted(seen)


def main(argv):
    if len(argv) < 2 or argv[1] not in ("static", "stale", "audit", "list"):
        print(__doc__, file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "audit":
        if len(argv) < 3:
            print(__doc__, file=sys.stderr)
            return 2
        root = Path(argv[3] if len(argv) > 3 else ".").resolve()
        missing = check_audit(argv[2], root)
        label = "reasons recorded during the test run have no catalog entry"
    else:
        root = Path(argv[2] if len(argv) > 2 else ".").resolve()
        if mode == "list":
            for reason, files in sorted(scan(root).items()):
                print(f"{reason}\t{','.join(files)}")
            return 0
        missing = check_static(root) if mode == "static" else check_stale(root)
        label = ("reasons in lib/ or bin/ have no entry in lib/status-reasons.json" if mode == "static"
                 else "catalog entries are no longer produced by lib/ or bin/")
    if missing:
        print(f"{len(missing)} {label}:", file=sys.stderr)
        for item in missing:
            print(f"  {item}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
