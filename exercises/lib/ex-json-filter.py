#!/usr/bin/env python3
"""ex-json-filter.py - apply a small jq-like filter to a JSON document.

Proxmox VE nodes do not have 'jq' installed. This program covers the
filters that the exercises use.

The filter arrives as the first argument, the JSON on the standard input.

Supported filters:

    length                    the number of elements
    .field                    a top level field
    .field // "default"       a field with a fallback
    .[] | select(.a == "b")   filter the elements
    .[] | select(.a >= 190)   filter the elements numerically
    .[] | .field              a field of every element
    .[] | select(...) | .f    a field of the matching elements
    .nodes // [] | join(",")  a joined array

Exit codes:

    0   the filter produced output
    1   the filter produced no output
"""
import json
import re
import sys

FILTER = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    DOC = json.load(sys.stdin)
except Exception:
    sys.exit(1)


def as_list(doc):
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        return [doc]
    return []


def get_field(doc, name):
    if isinstance(doc, dict):
        return doc.get(name)
    return None


def render(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"))
    return str(value)


def split_top(text, sep):
    """Split on a separator that is not inside a bracket or a string.

    A parenthesis counts as a bracket, so a '|' inside 'select(...)' does
    not split the pipeline.
    """
    parts = []
    depth = 0
    in_str = False
    quote = ""
    current = ""
    i = 0
    while i < len(text):
        ch = text[i]
        if in_str:
            current += ch
            if ch == "\\" and i + 1 < len(text):
                current += text[i + 1]
                i += 2
                continue
            if ch == quote:
                in_str = False
            i += 1
            continue
        if ch in "\"'":
            in_str = True
            quote = ch
            current += ch
            i += 1
            continue
        if ch in "[{(":
            depth += 1
        elif ch in "]})":
            depth -= 1
        if depth == 0 and text.startswith(sep, i):
            parts.append(current)
            current = ""
            i += len(sep)
            continue
        current += ch
        i += 1
    parts.append(current)
    return parts


SELECT_RE = re.compile(
    r"select\(\s*\.(\w+)\s*(==|>=|<=|>|<|!=)\s*([^\s)]+)\s*"
    r"(?:\s+and\s+\.(\w+)\s*(==|>=|<=|>|<|!=)\s*([^\s)]+)\s*)?\)"
)


def literal_value(text):
    """Turn a jq literal into a python value."""
    text = text.strip()
    if text in ("null", "empty"):
        return None
    if len(text) >= 2 and text[0] in "\"'" and text[-1] == text[0]:
        return text[1:-1]
    # An integer stays an integer - '9000' must not become '9000.0'.
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        return text


def compare(value, operator, literal):
    if operator == "==":
        if literal is None:
            return value is None
        if isinstance(literal, str):
            return render(value) == literal
        # A numeric comparison, with the string fallback that jq has.
        try:
            return float(value) == float(literal)
        except (TypeError, ValueError):
            return render(value) == render(literal)
    if operator == "!=":
        if literal is None:
            return value is not None
        if isinstance(literal, str):
            return render(value) != literal
        try:
            return float(value) != float(literal)
        except (TypeError, ValueError):
            return render(value) != render(literal)
    try:
        left = float(value)
        right = float(literal)
    except (TypeError, ValueError):
        return False
    if operator == ">=":
        return left >= right
    if operator == "<=":
        return left <= right
    if operator == ">":
        return left > right
    if operator == "<":
        return left < right
    return False


def eval_select(item, expression):
    match = SELECT_RE.search(expression)
    if not match:
        return True
    field, operator, literal = match.group(1), match.group(2), match.group(3)
    if not compare(get_field(item, field), operator, literal_value(literal)):
        return False
    # The optional second condition.
    if match.group(4):
        field2 = match.group(4)
        operator2 = match.group(5)
        literal2 = match.group(6)
        return compare(get_field(item, field2), operator2, literal_value(literal2))
    return True


def apply_field(doc, path):
    """Apply a dotted path, honouring '//' as the fallback operator.

    The path may contain the iteration step '.[]', which turns the
    document into a list of its elements.
    """
    fallback = None
    if "//" in path:
        path, fallback = path.split("//", 1)
        fallback = fallback.strip()
    current = doc
    parts = [p for p in path.strip().split(".") if p != ""]
    for part in parts:
        if part == "[]":
            current = as_list(current)
            continue
        if isinstance(current, list):
            current = [get_field(item, part) for item in current]
            current = [c for c in current if c is not None]
        elif isinstance(current, dict):
            current = current.get(part)
        else:
            current = None
        if current is None:
            if fallback is not None:
                current = fallback.strip("\"'")
            else:
                return None
    return current


def run_filter(doc, filt):
    filt = filt.strip()
    if filt == "length":
        return len(as_list(doc))

    steps = split_top(filt, "|")
    current = doc
    for step in steps:
        step = step.strip()
        if not step:
            continue
        if step == "[]" or step == ".[]":
            current = as_list(current)
            continue
        # A bracketed expression builds a new array out of a pipeline.
        if step.startswith("[") and step.endswith("]"):
            inner = step[1:-1].strip()
            value = run_filter(current, inner)
            current = as_list(value)
            continue
        if step.startswith("select("):
            current = [i for i in as_list(current) if eval_select(i, step)]
            continue
        if step == "length":
            current = len(as_list(current))
            continue
        if step in ("join(\",\")", "join(',')"):
            current = ",".join(render(i) for i in as_list(current))
            continue
        if step.startswith("."):
            current = apply_field(current, step)
            continue
        current = step
    return current


RESULT = run_filter(DOC, FILTER)

if isinstance(RESULT, list):
    if not RESULT:
        sys.exit(1)
    for item in RESULT:
        print(render(item))
else:
    text = render(RESULT)
    if text == "":
        sys.exit(1)
    print(text)
