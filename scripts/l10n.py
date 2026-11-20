#!/usr/bin/env python3
"""Interface languages for both apps: one catalog, l10n/strings.json, keyed by the Russian text.

  check       every text the Mac and Windows sources show has an English and a German translation,
              no Russian text is shown without L()/L``/tr(), the generated tables are current
  generate    writes the tables the apps read: Sources/XRayCore/Localization/Catalog.generated.swift
              and windows/src/core/l10n.generated.ts
  todo        prints, as JSON, the keys that still need a translation, with where each is used
  wrap-swift  wraps Russian string literals in the Swift sources in L(...) (migration helper)

Keys are the Russian texts with {0}, {1}... where the code interpolates values; counted words are
keyed "one|few|many" (Russian forms) and translated "one|other". A form may hold {n} to place the
number itself. Swift texts go through L("..."), TypeScript through L`...`, tr() or N().
"""
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "l10n", "strings.json")
SWIFT_OUT = os.path.join(ROOT, "Sources", "XRayCore", "Localization", "Catalog.generated.swift")
TS_OUT = os.path.join(ROOT, "windows", "src", "core", "l10n.generated.ts")
SWIFT_DIRS = [os.path.join(ROOT, "Sources"), os.path.join(ROOT, "iPad")]
SWIFT_SKIP = {"Sources/XRayCore/Localization/Catalog.generated.swift", "Sources/XRayCore/Localization/L10n.swift"}
LANGS = ("en", "de")
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
PLACEHOLDER = re.compile(r"\{(\d+|n)\}")

# MARK: Swift lexer


class SwiftString:
    def __init__(self, start, line):
        self.start, self.end, self.line = start, start, line
        self.segments = [""]
        self.interpolations = []  # token lists of the code inside \( ... )
        self.multiline = False

    @property
    def key(self):
        out = ""
        for i, segment in enumerate(self.segments):
            out += segment
            if i < len(self.segments) - 1:
                out += "{%d}" % i
        return out

    @property
    def russian(self):
        return any(CYRILLIC.search(s) for s in self.segments)


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


class SwiftLexer:
    def __init__(self, src):
        self.src = src
        self.lines = [0]
        for m in re.finditer("\n", src):
            self.lines.append(m.end())

    def line_of(self, pos):
        lo, hi = 0, len(self.lines) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.lines[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def skip_block_comment(self, i):
        depth, i = 1, i + 2
        while i < len(self.src) and depth:
            if self.src.startswith("/*", i):
                depth, i = depth + 1, i + 2
            elif self.src.startswith("*/", i):
                depth, i = depth - 1, i + 2
            else:
                i += 1
        return i

    def tokens(self, i, end, closing_paren=False):
        """Tokens of the code in [i, end); with closing_paren, stops at the unbalanced ')' and
        returns (tokens, index of that ')')."""
        src, out, depth = self.src, [], 0
        while i < end:
            c = src[i]
            if c in " \t\r\n":
                i += 1
            elif src.startswith("//", i):
                j = src.find("\n", i)
                i = end if j < 0 else j
            elif src.startswith("/*", i):
                i = self.skip_block_comment(i)
            elif c == '"' or (c == "#" and re.match(r'#+"', src[i:i + 8])):
                s = self.string(i)
                out.append(("str", s, s.start, s.end))
                i = s.end
            elif c.isalpha() or c == "_" or c == "$":
                j = i + 1
                while j < end and (src[j].isalnum() or src[j] == "_"):
                    j += 1
                out.append(("id", src[i:j], i, j))
                i = j
            elif c == "`":
                j = src.index("`", i + 1) + 1
                out.append(("id", src[i + 1:j - 1], i, j))
                i = j
            elif c.isdigit():
                j = i + 1
                while j < end and (src[j].isalnum() or src[j] in "_."):
                    if src[j] == "." and not (j + 1 < end and src[j + 1].isdigit()):
                        break
                    j += 1
                out.append(("num", src[i:j], i, j))
                i = j
            else:
                if closing_paren:
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        if depth == 0:
                            return out, i
                        depth -= 1
                out.append(("punct", c, i, i + 1))
                i += 1
        if closing_paren:
            raise ValueError("unterminated interpolation at line %d" % self.line_of(i))
        return out

    def string(self, i):
        src = self.src
        s = SwiftString(i, self.line_of(i))
        hashes = 0
        while src[i] == "#":
            hashes, i = hashes + 1, i + 1
        if src.startswith('"""', i):
            s.multiline, i = True, i + 3
            close = '"""' + "#" * hashes
        else:
            i += 1
            close = '"' + "#" * hashes
        escape = "\\" + "#" * hashes
        while True:
            if i >= len(src):
                raise ValueError("unterminated string at line %d" % s.line)
            if src.startswith(close, i):
                i += len(close)
                break
            if src.startswith(escape, i):
                k = i + len(escape)
                if src[k] == "(":
                    tokens, j = self.tokens(k + 1, len(src), closing_paren=True)
                    s.interpolations.append(tokens)
                    s.segments.append("")
                    i = j + 1
                    continue
                if src[k] == "u" and src[k + 1] == "{":
                    h = src.index("}", k)
                    s.segments[-1] += chr(int(src[k + 2:h], 16))
                    i = h + 1
                    continue
                s.segments[-1] += ESCAPES.get(src[k], src[k])
                i = k + 1
                continue
            if src[i] == "\n" and not s.multiline:
                raise ValueError("newline in string at line %d" % s.line)
            s.segments[-1] += src[i]
            i += 1
        s.end = i
        return s


def walk(tokens, visit):
    """Calls visit(tokens, index) for every string token, in nested interpolations too."""
    for index, token in enumerate(tokens):
        if token[0] == "str":
            visit(tokens, index)
            for inner in token[1].interpolations:
                walk(inner, visit)


def call_name(tokens, open_index):
    """Name of the function called by the '(' at open_index, and whether it is a member (x.f)."""
    if open_index > 0 and tokens[open_index - 1][0] == "id":
        member = open_index > 1 and tokens[open_index - 2][1] == "."
        return tokens[open_index - 1][1], member
    return None, False


def call_arguments(tokens, open_index):
    """Top-level arguments of the call whose '(' is at open_index, as token slices."""
    args, current, depth = [], [], 0
    for token in tokens[open_index + 1:]:
        if token[0] == "punct" and token[1] in "([{":
            depth += 1
        elif token[0] == "punct" and token[1] in ")]}":
            if depth == 0:
                args.append(current)
                return args
            depth -= 1
        if depth == 0 and token[0] == "punct" and token[1] == ",":
            args.append(current)
            current = []
        else:
            current.append(token)
    return args


STATIC_LET = re.compile(r"^\s*(?:(?:private|fileprivate|public|internal|nonisolated)\s+)*static\s+let\b|^let\b|^private\s+let\b|^fileprivate\s+let\b")


def scan_swift(path):
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    src = open(path, encoding="utf-8").read()
    lexer = SwiftLexer(src)
    tokens = lexer.tokens(0, len(src))
    keys, problems, wraps = [], [], []

    def visit(toks, i):
        s = toks[i][1]
        prev = toks[i - 1] if i > 0 else (None, None, 0, 0)
        prev2 = toks[i - 2] if i > 1 else (None, None, 0, 0)
        nxt = toks[i + 1] if i + 1 < len(toks) else (None, None, 0, 0)
        if prev[1] == "(":
            name, member = call_name(toks, i - 1)
            stored = name == "key" and member and i > 3 and toks[i - 4][1] == "L10n"
            if ((name in ("L", "N") and not member) or stored) and nxt[1] == ")":
                keys.append({"key": s.key, "file": rel, "line": s.line})
                return
        # Fmt.plural(count, "one", "few", "many"): the three forms are one plural key.
        for back in range(i - 1, max(i - 60, -1), -1):
            t = toks[back]
            if t[1] == "(" and call_name(toks, back)[0] == "plural":
                args = call_arguments(toks, back)
                if len(args) == 4 and all(len(a) == 1 and a[0][0] == "str" for a in args[1:]) and any(a[0][1] is s for a in args[1:]):
                    if args[1][0][1] is s:
                        keys.append({"key": "|".join(a[0][1].key for a in args[1:]), "plural": True, "file": rel, "line": s.line})
                    return
                break
        if not s.russian:
            return
        # Identifiers: enum raw values, case patterns, comparisons. Shown through L10n.tr(...).
        if (prev[1] == "=" and prev2[0] == "id" and i > 2 and toks[i - 3][1] == "case") or prev[1] == "case" \
                or (prev[1] == "=" and prev2[1] in ("=", "!")) or (nxt[1] in ("=", "!") and i + 2 < len(toks) and toks[i + 2][1] == "="):
            keys.append({"key": s.key, "file": rel, "line": s.line, "identifier": True})
            return
        problems.append({"file": rel, "line": s.line, "text": src[s.start:s.end][:90], "problem": "Russian text without L()"})
        wraps.append(s)

    walk(tokens, visit)

    # L() in a static or global constant runs once, before the user can switch the language.
    depth_open = None
    for lineno, line in enumerate(src.split("\n"), 1):
        if depth_open is None and STATIC_LET.search(line) and "=" in line and "{" not in line.split("=", 1)[0]:
            depth_open = 0
            start = lineno
        if depth_open is not None:
            depth_open += line.count("(") + line.count("[") - line.count(")") - line.count("]")
            if re.search(r"\bL\(", line):
                problems.append({"file": rel, "line": lineno, "text": line.strip()[:90],
                                 "problem": "L() in a constant runs once, before the language is set: make it a computed property"})
            if depth_open <= 0 and not line.rstrip().endswith(("=", ",", "[", "(")):
                depth_open = None
    return keys, problems, wraps, src


def swift_files():
    for base in SWIFT_DIRS:
        for dirpath, _, names in os.walk(base):
            for name in sorted(names):
                if name.endswith(".swift"):
                    path = os.path.join(dirpath, name)
                    if os.path.relpath(path, ROOT).replace(os.sep, "/") not in SWIFT_SKIP:
                        yield path


def swift_keys():
    keys, problems = [], []
    for path in swift_files():
        k, p, _, _ = scan_swift(path)
        keys += k
        problems += p
    return keys, problems


def ts_keys():
    windows = os.path.join(ROOT, "windows")
    tsx = os.path.join(windows, "node_modules", ".bin", "tsx")
    if not os.path.exists(tsx):
        sys.exit("windows/node_modules is missing: run `npm ci` in windows/ first")
    out = subprocess.run([tsx, "scripts/l10n.ts", "keys"], cwd=windows, capture_output=True, text=True, check=True).stdout
    data = json.loads(out)
    for item in data["keys"] + data["problems"]:
        item["file"] = "windows/" + item["file"]
    return data["keys"], data["problems"]


# MARK: Catalog


def load_catalog():
    if not os.path.exists(CATALOG):
        return {"strings": {}, "plurals": {}}
    with open(CATALOG, encoding="utf-8") as f:
        data = json.load(f)
    return {"strings": data.get("strings", {}), "plurals": data.get("plurals", {})}


def save_catalog(catalog):
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    data = {
        "comment": "Interface texts of S2A Claude X-Ray (Mac and Windows), keyed by the Russian text. "
                   "{0}, {1}... are values filled in by the code; plurals are keyed one|few|many and translated one|other, "
                   "{n} places the number. Run `python3 scripts/l10n.py check` after editing, then `generate`.",
        "strings": dict(sorted(catalog["strings"].items())),
        "plurals": dict(sorted(catalog["plurals"].items())),
    }
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")


def tables(catalog):
    """The compact form both apps read: {strings: {key: {en, de}}, plurals: {key: {en, de}}}."""
    pick = lambda entries: {k: {lang: v[lang] for lang in LANGS if v.get(lang)} for k, v in sorted(entries.items())}
    return {"strings": pick(catalog["strings"]), "plurals": pick(catalog["plurals"])}


def swift_source(catalog):
    payload = json.dumps(tables(catalog), ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    assert '"""#' not in payload and "\\#" not in payload
    lines = "\n".join("    " + chunk for chunk in wrap_json(payload))
    return ("// Generated by scripts/l10n.py from l10n/strings.json. Do not edit: edit the catalog and run\n"
            "// `python3 scripts/l10n.py generate`.\n\n"
            "extension L10n {\n"
            "    static let catalogJSON = #\"\"\"\n" + lines + "\n    \"\"\"#\n}\n")


def wrap_json(payload, width=150):
    """Splits the JSON between entries so the Swift literal stays readable; newlines are JSON whitespace."""
    parts, line = [], ""
    for piece in re.split(r'(?<=\}),(?=")', payload):
        if line and len(line) + len(piece) > width:
            parts.append(line + ",")
            line = piece
        else:
            line = piece if not line else line + "," + piece
    parts.append(line)
    return parts


def ts_source(catalog):
    t = tables(catalog)
    dump = lambda d: json.dumps(d, ensure_ascii=False, indent=1, sort_keys=True)
    return ("// Generated by scripts/l10n.py from l10n/strings.json. Do not edit: edit the catalog and run\n"
            "// `python3 scripts/l10n.py generate`.\n\n"
            "export const STRINGS: Record<string, { en?: string; de?: string }> = " + dump(t["strings"]) + ";\n\n"
            "export const PLURALS: Record<string, { en?: string; de?: string }> = " + dump(t["plurals"]) + ";\n")


# MARK: Commands


def collect():
    sk, sp = swift_keys()
    tk, tp = ts_keys()
    return sk + tk, sp + tp


def placeholders(text):
    return sorted(set(m.group(1) for m in PLACEHOLDER.finditer(text) if m.group(1) != "n"))


def check():
    keys, problems = collect()
    catalog = load_catalog()
    used_strings, used_plurals = defaultdict(list), defaultdict(list)
    for k in keys:
        (used_plurals if k.get("plural") else used_strings)[k["key"]].append(f"{k['file']}:{k['line']}")
    failures = []
    for p in problems:
        failures.append(f"{p['file']}:{p['line']}: {p['problem']}: {p['text']}")
    for kind, used, entries in (("text", used_strings, catalog["strings"]), ("plural", used_plurals, catalog["plurals"])):
        for key, where in sorted(used.items()):
            entry = entries.get(key, {})
            for lang in LANGS:
                if not entry.get(lang):
                    failures.append(f"{where[0]}: no {lang} {kind} for {key!r}")
                elif kind == "text" and placeholders(entry[lang]) != placeholders(key):
                    failures.append(f"{where[0]}: {lang} {kind} for {key!r} has placeholders {placeholders(entry[lang])}, the key {placeholders(key)}")
                elif kind == "plural" and len(entry[lang].split("|")) != 2:
                    failures.append(f"{where[0]}: {lang} plural for {key!r} needs two forms one|other: {entry[lang]!r}")
        for key in sorted(set(entries) - set(used)):
            failures.append(f"l10n/strings.json: {kind} {key!r} is not used any more")
    for path, text in ((SWIFT_OUT, swift_source(catalog)), (TS_OUT, ts_source(catalog))):
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            failures.append(f"{os.path.relpath(path, ROOT)} is out of date: run `python3 scripts/l10n.py generate`")
    texts, plurals = len(used_strings), len(used_plurals)
    if failures:
        print("\n".join(failures))
        print(f"\n{len(failures)} problem(s); {texts} texts and {plurals} plurals in use")
        sys.exit(1)
    print(f"l10n: {texts} texts and {plurals} plurals, all translated into {', '.join(LANGS)}")


def generate():
    catalog = load_catalog()
    save_catalog(catalog)
    for path, text in ((SWIFT_OUT, swift_source(catalog)), (TS_OUT, ts_source(catalog))):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote", os.path.relpath(path, ROOT))


def todo():
    keys, _ = collect()
    catalog = load_catalog()
    missing = {}
    for k in keys:
        entries = catalog["plurals" if k.get("plural") else "strings"]
        entry = entries.get(k["key"], {})
        if all(entry.get(lang) for lang in LANGS):
            continue
        item = missing.setdefault(k["key"], {"plural": bool(k.get("plural")), "used": []})
        item["used"].append(f"{k['file']}:{k['line']}")
    json.dump(missing, sys.stdout, ensure_ascii=False, indent=1)
    print()


def wrap_swift(paths):
    for path in paths or list(swift_files()):
        _, _, wraps, src = scan_swift(os.path.abspath(path))
        if not wraps:
            continue
        edits = []
        for s in wraps:
            edits.append((s.end, ")"))
            edits.append((s.start, "L("))
        for pos, text in sorted(edits, key=lambda e: e[0], reverse=True):
            src = src[:pos] + text + src[pos:]
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        print(f"{os.path.relpath(path, ROOT)}: {len(wraps)} texts")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "check":
        check()
    elif command == "generate":
        generate()
    elif command == "todo":
        todo()
    elif command == "wrap-swift":
        wrap_swift(sys.argv[2:])
    else:
        print(__doc__)
        sys.exit(2)
