"""Parser for WoW SavedVariables files (the subset of Lua the client writes).

The client writes plain assignments of literal tables:

    ForeverScribeDB = {
        ["chars"] = {
            ["Realm:Name"] = { ... },
        },
        "value", -- [1]
    }

Supported: strings with Lua escapes, numbers (incl. hex, exponents, inf/nan
spellings the client emits), true/false/nil, nested tables with [key] =, name =
and positional entries, and -- / --[[ ]] comments. Tables whose keys are exactly
1..n become Python lists; everything else becomes a dict (integer keys kept as
int). Anything else raises SVParseError, so a truncated or half-synced file is
rejected instead of being half-ingested.
"""

import math
import re

__all__ = ["SVParseError", "parse_saved_variables", "parse_file"]


class SVParseError(ValueError):
    pass


_NUM = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
        "\\": "\\", '"': '"', "'": "'", "\n": "\n"}


class _P:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def err(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise SVParseError("%s at line %d (offset %d of %d)" % (msg, line, self.i, self.n))

    def ws(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n\f\v":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i) or re.match(r"--\[=*\[", s[self.i:self.i + 8]):
                    m = re.match(r"--\[(=*)\[", s[self.i:])
                    close = "]" + m.group(1) + "]"
                    j = s.find(close, self.i)
                    if j < 0:
                        self.err("unterminated long comment")
                    self.i = j + len(close)
                else:
                    j = s.find("\n", self.i)
                    self.i = n if j < 0 else j + 1
            elif c == ";":
                self.i += 1
            else:
                break

    def peek(self):
        self.ws()
        return self.s[self.i] if self.i < self.n else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.err("expected %r" % ch)
        self.i += 1

    def string(self):
        q = self.s[self.i]
        if q == "[":
            m = re.match(r"\[(=*)\[", self.s[self.i:])
            if not m:
                self.err("bad long string")
            close = "]" + m.group(1) + "]"
            start = self.i + len(m.group(0))
            j = self.s.find(close, start)
            if j < 0:
                self.err("unterminated long string")
            self.i = j + len(close)
            body = self.s[start:j]
            return body[1:] if body.startswith("\n") else body
        self.i += 1
        out = []
        s, n = self.s, self.n
        while True:
            if self.i >= n:
                self.err("unterminated string")
            c = s[self.i]
            if c == q:
                self.i += 1
                break
            if c == "\n":
                self.err("newline in string")
            if c == "\\":
                self.i += 1
                if self.i >= n:
                    self.err("unterminated escape")
                e = s[self.i]
                if e in _ESC:
                    out.append(_ESC[e])
                    self.i += 1
                elif e.isdigit():
                    m = re.match(r"\d{1,3}", s[self.i:])
                    out.append(chr(int(m.group(0)) & 0xFF))
                    self.i += len(m.group(0))
                elif e == "x":
                    out.append(chr(int(s[self.i + 1:self.i + 3], 16)))
                    self.i += 3
                else:
                    out.append(e)
                    self.i += 1
            else:
                j = self.i
                while j < n and s[j] not in (q, "\\", "\n"):
                    j += 1
                out.append(s[self.i:j])
                self.i = j
        raw = "".join(out)
        # The client writes UTF-8 bytes; \ddd escapes produce raw bytes too.
        try:
            return raw.encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return raw

    def number(self):
        s = self.s
        for word, val in (("inf", math.inf), ("-inf", -math.inf), ("nan", math.nan), ("-nan", math.nan)):
            if s.startswith(word, self.i) and not s[self.i + len(word):self.i + len(word) + 1].isalnum():
                self.i += len(word)
                return val
        m = _NUM.match(s, self.i)
        if not m:
            self.err("bad number")
        self.i = m.end()
        t = m.group(0)
        if "x" in t.lower():
            return int(t, 16)
        if re.fullmatch(r"-?\d+", t):
            return int(t)
        return float(t)

    def value(self, depth=0):
        if depth > 200:
            self.err("nesting too deep")
        c = self.peek()
        if c == "{":
            return self.table(depth)
        if c in "\"'":
            return self.string()
        if c == "[" and re.match(r"\[=*\[", self.s[self.i:self.i + 8]):
            return self.string()
        if c == "-" or c == "." or c.isdigit():
            return self.number()
        m = _NAME.match(self.s, self.i)
        if m:
            w = m.group(0)
            if w in ("true", "false", "nil"):
                self.i = m.end()
                return {"true": True, "false": False, "nil": None}[w]
            if w in ("inf", "nan"):
                return self.number()
        if not c:
            self.err("unexpected end of file")
        self.err("unexpected %r" % c)

    def table(self, depth):
        self.expect("{")
        pos = []
        keyed = {}
        while True:
            c = self.peek()
            if c == "}":
                self.i += 1
                break
            if not c:
                self.err("unexpected end of file in table")
            if c == "[" and not re.match(r"\[=*\[", self.s[self.i:self.i + 8]):
                self.i += 1
                k = self.value(depth + 1)
                self.expect("]")
                self.expect("=")
                v = self.value(depth + 1)
                if isinstance(k, float) and k.is_integer():
                    k = int(k)
                if v is not None:
                    keyed[k] = v
            else:
                m = _NAME.match(self.s, self.i)
                save = self.i
                if m and m.group(0) not in ("true", "false", "nil"):
                    self.i = m.end()
                    if self.peek() == "=":
                        self.i += 1
                        v = self.value(depth + 1)
                        if v is not None:
                            keyed[m.group(0)] = v
                    else:
                        self.i = save
                        pos.append(self.value(depth + 1))
                else:
                    pos.append(self.value(depth + 1))
            c = self.peek()
            if c == ",":
                self.i += 1
            elif c == "}":
                continue
            elif not c:
                self.err("unexpected end of file in table")
            else:
                self.err("expected ',' or '}'")
        if pos:
            for idx, v in enumerate(pos, 1):
                if v is not None:
                    keyed.setdefault(idx, v)
        if not keyed:
            return {}
        ints = [k for k in keyed if isinstance(k, int) and not isinstance(k, bool)]
        if len(ints) == len(keyed) and sorted(ints) == list(range(1, len(ints) + 1)):
            return [keyed[i] for i in range(1, len(ints) + 1)]
        return keyed


def parse_saved_variables(text):
    """Return {global_name: value} for every top-level assignment."""
    if text.startswith("\ufeff"):
        text = text[1:]
    p = _P(text)
    out = {}
    while True:
        p.ws()
        if p.i >= p.n:
            break
        m = _NAME.match(p.s, p.i)
        if not m:
            p.err("expected a global assignment")
        p.i = m.end()
        p.expect("=")
        out[m.group(0)] = p.value()
    if not out:
        raise SVParseError("empty SavedVariables file")
    return out


def parse_file(path):
    with open(path, "rb") as fh:
        data = fh.read()
    # Parse byte-for-byte; each string is re-decoded as UTF-8 in _P.string().
    return parse_saved_variables(data.decode("latin-1")), data
