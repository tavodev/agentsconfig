#!/usr/bin/env python3
"""Refresh scripts/docs-reference/{claude,codex,gemini,opencode}.json from the
official docs.

Downloads the Claude Code settings reference (+ the SchemaStore schema it
publishes), the Codex config reference and the Gemini CLI and OpenCode JSON
schemas, then rewrites, per key: English
summary, value kind, known options, default, scopes, topic and deprecation.
Spanish summaries are preserved; new keys are reported so they can be
translated before running scripts/generate-docs-reference.py.

    python3 scripts/refresh-docs-reference.py [--offline DIR]

--offline DIR reads cref.md, cc-schema.json, codex.md, gem-schema.json and
oc-schema.json from DIR instead of downloading them.
"""
import argparse
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "scripts" / "docs-reference"
SOURCES = {
    "cref.md": "https://code.claude.com/docs/en/settings-reference.md",
    "cc-schema.json": "https://json.schemastore.org/claude-code-settings.json",
    "codex.md": "https://developers.openai.com/codex/config-reference.md",
    "gem-schema.json": "https://raw.githubusercontent.com/google-gemini/gemini-cli/main/schemas/settings.schema.json",
    "oc-schema.json": "https://opencode.ai/config.json",
}
LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")


def fetch(offline):
    out = {}
    for name, url in SOURCES.items():
        if offline:
            out[name] = (pathlib.Path(offline) / name).read_text()
        else:
            req = urllib.request.Request(url, headers={"User-Agent": "agentsconfig-docs-refresh"})
            with urllib.request.urlopen(req, timeout=30) as r:
                out[name] = r.read().decode()
    return out


def sentence(text):
    text = LINK.sub(r"\1", text).strip()
    return text if text.endswith((".", ")")) else text + "."


def json_literal(text):
    """`true`, `"auto"`, `30`, `[]` at the start of a Default line."""
    m = re.match(r"`([^`]+)`", text.strip())
    if not m:
        return None
    try:
        json.loads(m.group(1))
        return m.group(1)
    except ValueError:
        return None


# MARK: Claude Code

SCOPES = {
    "Any file": ["user", "project", "local", "managed"],
    "Managed": ["managed"],
    "User or managed": ["user", "managed"],
    "User, local, or managed": ["user", "local", "managed"],
    "User": ["user"],
    "Global config": ["globalConfig"],
}


def claude(src):
    text, schema = src["cref.md"], json.loads(src["cc-schema.json"])
    props = schema.get("properties", {})
    index = {}
    for line in text.split("## Settings index", 1)[1].split("\n## ", 1)[0].split("\n"):
        m = re.match(r"^\| \[`([^`]+)`\]\(#[^)]*\) \| (.*?) \| ([^|]*) \| [^|]* \|$", line)
        if m:
            index[m.group(1)] = (sentence(m.group(2)), m.group(3).strip())
    out = {}
    for chunk in re.split(r"\n(?=### `)", text):
        if not chunk.startswith("### `"):
            continue
        key = chunk[5:].split("`")[0]
        if key not in index:
            continue
        summary, topic = index[key]

        def field(name):
            m = re.search(r"^\* \*\*" + name + r"\*\*: (.*)$", chunk, re.M)
            return m.group(1) if m else ""

        type_line, default_line, scope_line = field("Type"), field("Default"), field("Scope")
        lowered = type_line.lower()
        options, custom = [], True
        if lowered.startswith("boolean"):
            kind = "bool"
        elif lowered.startswith("string, one of:"):
            block = chunk.split(type_line, 1)[1].split("\n* ", 1)[0]
            options = re.findall(r'^  \* `"([^"`]+)"`', block, re.M)
            kind, custom = "string", not options
        elif lowered.startswith("string") or lowered.startswith("the string"):
            kind = "string"
            options = re.findall(r'`"([^"`]+)"`', type_line)
            exclusive = re.match(r'^(string, one of `|the string `)', type_line) and not re.search(
                r"\bor (a|an|any|the name|another)\b|such as|custom", type_line)
            custom = not (options and exclusive)
            if lowered.startswith("string, one uuid") or "array" in lowered:
                kind = "other"
        elif lowered.startswith(("number", "integer")):
            kind = "integer" if lowered.startswith("integer") else "number"
        elif lowered.startswith("array"):
            kind = "array"
        elif lowered.startswith("object"):
            kind = "object"
        else:
            kind = "other"
        # SchemaStore enums are authoritative where the schema has them.
        prop = props.get(key) if "." not in key else None
        if prop and kind == "string":
            enum = prop.get("enum")
            alts = prop.get("anyOf", []) + prop.get("oneOf", [])
            for alt in alts:
                enum = enum or alt.get("enum")
            if enum:
                options = [v for v in enum if isinstance(v, str)]
                custom = any("enum" not in a and a.get("type") == "string" for a in alts)
        lo = hi = None
        rng = re.search(r"from `(\d+)` to `(\d+)`", type_line)
        if rng:
            lo, hi = float(rng.group(1)), float(rng.group(2))
        mn = re.search(r"minimum `(\d+)`", type_line)
        if mn:
            lo = float(mn.group(1))
        scope_name = re.match(r"\[`([^`]+)`\]", scope_line)
        scopes = SCOPES.get(scope_name.group(1) if scope_name else "", ["user", "project", "local", "managed"])
        out[key] = {
            "en": summary,
            "kind": kind,
            "options": options,
            "custom": custom if options else True,
            "default": json_literal(default_line),
            "scopes": scopes,
            "topic": topic,
            "deprecated": bool(re.search(r"Deprecated", chunk[:800])),
            "min": lo,
            "max": hi,
        }
    return out


# MARK: Codex

CODEX_USER_ONLY = {"openai_base_url", "chatgpt_base_url", "apps_mcp_product_sku", "model_provider",
                   "model_providers", "notify", "profile", "profiles",
                   "experimental_realtime_ws_base_url", "otel"}


def codex(src):
    text = src["codex.md"]
    section = text[text.index("## `config.toml`"):text.index("## `requirements.toml`")]
    out = {}
    pattern = r'key:\s*"([^"]+)",\s*type:\s*"([^"]*)",\s*description:\s*((?:"(?:[^"\\]|\\.)*"\s*\+?\s*)+)'
    for m in re.finditer(pattern, section):
        key, type_text = m.group(1), m.group(2)
        if " " in key:
            continue
        desc = "".join(json.loads(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"', m.group(3)))
        t = type_text.strip()
        options, custom, kind = [], True, "other"
        if t.startswith("boolean"):
            kind = "bool"
        elif t.startswith(("integer", "number")):
            kind = "integer" if t.startswith("integer") else "number"
        elif t.startswith(("array", "empty array")):
            kind = "array"
        elif t.startswith(("table", "map")):
            kind = "object"
        elif t.startswith("string"):
            kind = "string"
        else:
            parts = [p.strip() for p in t.split("|")]
            words = [p for p in parts if re.fullmatch(r"[a-z0-9_.\-]+", p)]
            if words:
                kind, options = "string", words
                custom = len(words) != len(parts)
        default = None
        d = re.search(r"[Dd]efault(?:s to|:)?\s*`([^`]+)`", desc)
        if d:
            raw = d.group(1)
            for candidate in (raw, json.dumps(raw)):
                try:
                    value = json.loads(candidate)
                except ValueError:
                    continue
                if kind == "string" and isinstance(value, str) or kind == "bool" and isinstance(value, bool) \
                        or kind in ("integer", "number") and isinstance(value, (int, float)) and not isinstance(value, bool):
                    default = candidate
                    break
        rng = re.search(r"\((\d+)[–-](\d+)\)", t)
        lo = 0.0 if "nonnegative" in t else 1.0 if "positive" in t else None
        hi = None
        if rng:
            lo, hi = float(rng.group(1)), float(rng.group(2))
        top = key.split(".")[0]
        out[key] = {
            "en": sentence(desc),
            "kind": kind,
            "options": options,
            "custom": custom if options else True,
            "default": default,
            "scopes": ["user"] if top in CODEX_USER_ONLY else ["user", "project"],
            "topic": top if "." in key else "General",
            "deprecated": bool(re.match(r"(Deprecated|Legacy)\b", desc)),
            "min": lo,
            "max": hi,
        }
    return out


# MARK: JSON Schema (Gemini CLI, OpenCode)

def from_schema(schema, scopes):
    """Every described property, with `<name>` for map entries
    (additionalProperties objects) such as `mcpServers.<name>.command`."""
    defs = schema.get("$defs") or schema.get("definitions") or {}

    def resolve(node, depth=0):
        while isinstance(node, dict) and "$ref" in node and depth < 20:
            node = defs.get(node["$ref"].split("/")[-1], {})
            depth += 1
        if isinstance(node, dict) and "allOf" in node and len(node["allOf"]) == 1:
            merged = dict(resolve(node["allOf"][0]))
            merged.update({k: v for k, v in node.items() if k != "allOf"})
            return merged
        return node if isinstance(node, dict) else {}

    def alternatives(node):
        alts = node.get("anyOf") or node.get("oneOf") or []
        return [resolve(a) for a in alts]

    def describe(node):
        types = node.get("type")
        types = types if isinstance(types, list) else [types] if types else []
        options = [v for v in node.get("enum", []) if isinstance(v, str)]
        for alt in alternatives(node):
            alt_type = alt.get("type")
            if alt_type and alt_type != "null":
                types.append(alt_type if isinstance(alt_type, str) else alt_type[0])
            options += [v for v in alt.get("enum", []) if isinstance(v, str)]
            if "const" in alt and isinstance(alt["const"], str):
                options.append(alt["const"])
        types = [t for t in types if t != "null"]
        kind = {"boolean": "bool", "string": "string", "integer": "integer", "number": "number",
                "array": "array", "object": "object"}.get(types[0] if types else "", "other")
        if options and not types:
            kind = "string"
        custom = not options or any(a.get("type") == "string" and "enum" not in a and "const" not in a
                                     for a in alternatives(node))
        if len(set(types)) > 1 and kind != "string":
            kind = "other"
        default = node.get("default")
        default_json = json.dumps(default) if isinstance(default, (bool, int, float, str)) else None
        return kind, list(dict.fromkeys(options)), custom, default_json

    out = {}

    def walk(props, prefix, depth):
        for key, raw in props.items():
            node = resolve(raw)
            path = prefix + [key]
            text = node.get("description") or raw.get("description") if isinstance(raw, dict) else None
            if text and key != "$schema":
                kind, options, custom, default = describe(node)
                out[".".join(path)] = {
                    "en": sentence(text.split("\n\n")[0]),
                    "kind": kind,
                    "options": options,
                    "custom": custom if options else True,
                    "default": default,
                    # Gemini `admin.*` is pushed by enterprise admins, never set in a user file.
                    "scopes": ["managed"] if path[0] == "admin" else scopes,
                    "topic": path[0] if len(path) > 1 else "General",
                    "deprecated": bool(node.get("deprecated")) or bool(re.match(r"(?i)@?deprecated", text)),
                    "min": node.get("minimum"),
                    "max": node.get("maximum"),
                }
            if depth >= 4:
                continue
            if isinstance(node.get("properties"), dict):
                walk(node["properties"], path, depth + 1)
            extra = resolve(node.get("additionalProperties")) if isinstance(node.get("additionalProperties"), dict) else {}
            if isinstance(extra.get("properties"), dict):
                walk(extra["properties"], path + ["<name>"], depth + 1)

    walk(resolve(schema).get("properties", {}), [], 0)
    return out


def merge(name, fresh):
    path = DATA / f"{name}.json"
    old = json.loads(path.read_text()) if path.exists() else {}
    missing = []
    for key, entry in fresh.items():
        previous = old.get(key, {})
        if previous.get("en") == entry["en"] and previous.get("es"):
            entry["es"] = previous["es"]
        elif previous.get("es") and previous.get("en", "").rstrip(".") == entry["en"].rstrip("."):
            entry["es"] = previous["es"]
        else:
            entry["es"] = previous.get("es", "")
            missing.append(key)
    path.write_text(json.dumps(fresh, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    removed = sorted(set(old) - set(fresh))
    print(f"{name}: {len(fresh)} keys; removed {removed or 'none'}")
    if missing:
        print(f"{name}: translate or review 'es' for: {', '.join(missing)}", file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--offline")
    args = parser.parse_args()
    src = fetch(args.offline)
    merge("claude", claude(src))
    merge("codex", codex(src))
    merge("gemini", from_schema(json.loads(src["gem-schema.json"]), ["user", "project", "managed"]))
    merge("opencode", from_schema(json.loads(src["oc-schema.json"]), ["user", "project"]))
