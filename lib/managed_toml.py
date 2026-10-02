"""Apply owned/seeded TOML keys to a personal config, preserving everything else.

Usage: managed_toml.py DEST RENDERED RAW RULES_JSON OUT
Exit 0 writes OUT; exit 3 means DEST is not valid TOML and must stay untouched.
"""

import copy
import importlib.util
import json
from pathlib import Path
import sys

VENDOR = Path(__file__).resolve().parent / "vendor" / "tomlkit"


def load_tomlkit():
    spec = importlib.util.spec_from_file_location(
        "tomlkit", str(VENDOR / "__init__.py"), submodule_search_locations=[str(VENDOR)]
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["tomlkit"] = module
    spec.loader.exec_module(module)
    return module


tomlkit = load_tomlkit()
MISSING = object()


def split(rule):
    if rule.endswith(".*"):
        return rule[:-2].split("."), "each"
    if rule.endswith("[]"):
        return rule[:-2].split("."), "union"
    return rule.split("."), "whole"


def get(doc, path):
    node = doc
    for key in path:
        if not hasattr(node, "get") or key not in node:
            return MISSING
        node = node[key]
    return node


def parent(doc, path):
    node = doc
    for key in path[:-1]:
        if key not in node:
            node[key] = tomlkit.table(is_super_table=True)
        node = node[key]
    return node


def put(doc, path, value):
    parent(doc, path)[path[-1]] = copy.deepcopy(value)


def plain(value):
    unwrap = getattr(value, "unwrap", None)
    return unwrap() if callable(unwrap) else value


def apply(doc, rendered, raw, rules, retired):
    for rule in rules.get("owned", []):
        path, kind = split(rule)
        incoming = get(rendered, path)
        if kind == "each":
            current = get(doc, path)
            stripped = get(raw, path)
            if stripped is not MISSING and current is not MISSING:
                for key in list(stripped.keys()):
                    if incoming is not MISSING and key in incoming:
                        continue
                    mine = current.get(key) if hasattr(current, "get") else None
                    url = plain(stripped[key]).get("url") if hasattr(stripped[key], "get") else None
                    if mine is not None and hasattr(mine, "get") and url and plain(mine).get("url") == url:
                        del current[key]
            if incoming is MISSING:
                continue
            for key in incoming.keys():
                if plain(get(doc, path + [key])) != plain(incoming[key]):
                    put(doc, path + [key], incoming[key])
        elif incoming is MISSING:
            continue
        elif kind == "union":
            current = get(doc, path)
            if current is MISSING:
                put(doc, path, incoming)
                continue
            for item in incoming:
                if plain(item) not in plain(current):
                    current.append(plain(item))
        elif plain(get(doc, path)) != plain(incoming):
            put(doc, path, incoming)
    for rule in rules.get("seeded", []):
        path, kind = split(rule)
        incoming = get(rendered, path)
        if incoming is MISSING:
            continue
        keys = [path + [key] for key in incoming.keys()] if kind == "each" else [path]
        for key_path in keys:
            if get(doc, key_path) is MISSING:
                put(doc, key_path, get(rendered, key_path))
    for entry in retired:
        current = get(doc, entry["path"])
        if current is not MISSING and plain(current) in entry["shipped"]:
            del parent(doc, entry["path"])[entry["path"][-1]]


def main(dest, rendered, raw, rules_json, out):
    rules = json.loads(rules_json)
    try:
        doc = tomlkit.parse(Path(dest).read_text(encoding="utf-8"))
    except Exception:
        return 3
    apply(
        doc,
        tomlkit.parse(Path(rendered).read_text(encoding="utf-8")),
        tomlkit.parse(Path(raw).read_text(encoding="utf-8")),
        rules,
        rules.get("retired", []),
    )
    Path(out).write_text(tomlkit.dumps(doc), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:6]))
