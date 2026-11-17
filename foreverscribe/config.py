"""Per-user configuration, kept outside the repository.

Location (first that applies):
  $FOREVERSCRIBE_CONFIG
  Windows: %APPDATA%\\foreverscribe\\config.toml
  macOS/Linux: $XDG_CONFIG_HOME/foreverscribe/config.toml  (default ~/.config/foreverscribe/config.toml)

Data directory: `data_dir` key, else $FOREVERSCRIBE_DATA, else
  Windows: %LOCALAPPDATA%\\foreverscribe   macOS/Linux: $XDG_DATA_HOME/foreverscribe (~/.local/share/foreverscribe)

Python 3.11+ parses with tomllib; older Pythons (macOS ships 3.9) use the small parser below,
which covers what config.example.toml uses: [tables], key = "string" | 'literal' | int | float |
true/false | [arrays of those], comments.
"""

import copy
import glob
import os
import re
import sys

try:  # Python 3.11+
    import tomllib as _tomllib  # type: ignore
except Exception:  # pragma: no cover - depends on interpreter
    _tomllib = None

DEFAULTS = {
    "data_dir": "",
    "default_character": "",
    "wow": {"dir": "", "accounts": []},
    "sources": {"extra": [], "live_dir": ""},
    "transport": {"mode": "local", "folder": ""},
    "receiver": {"bind": "127.0.0.1", "port": 8766, "public_url": "", "allow_ips": [], "legacy_unsigned_ips": [],
                 "keys_file": "", "max_skew_seconds": 600},
    "relay": {"url": "", "create_secret": ""},
    "pull": {"ssh_host": "", "ssh_command": "ssh -o BatchMode=yes -o ConnectTimeout=8", "remote_account_dir": ""},
    "sync": {"extra_saved_variables": ["ForeverForge*.lua", "Polestar.lua"]},
    "ah": {"enabled": False, "wowgg_key": "", "market": "", "cut": ""},
    "wowhead": {"cache_dir": "", "page_dir": "", "extra_page_dirs": []},
    "summary": {"max_lines": 40},
}

# Where WoW: Forever usually lives (first existing wins when wow.dir is empty).
WOW_CANDIDATES = {
    "darwin": ["/Applications/World of Warcraft/_forever_"],
    "win32": [r"C:\Program Files (x86)\World of Warcraft\_forever_", r"C:\Program Files\World of Warcraft\_forever_",
              r"D:\World of Warcraft\_forever_"],
    "linux": ["~/Games/world-of-warcraft/drive_c/Program Files (x86)/World of Warcraft/_forever_"],
}


class ConfigError(ValueError):
    pass


# ---------------------------------------------------------------- TOML subset
_KEY = r'(?:[A-Za-z0-9_-]+|"[^"]*")'


def _strip_comment(line):
    out, q = [], None
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            if c == "\\" and q == '"' and i + 1 < len(line):
                out.append(c + line[i + 1])
                i += 2
                continue
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "#":
            break
        out.append(c)
        i += 1
    return "".join(out).strip()


def _value(s, where):
    s = s.strip()
    if not s:
        raise ConfigError("%s: missing value" % where)
    if s[0] == '"':
        if not s.endswith('"') or len(s) < 2:
            raise ConfigError("%s: unterminated string" % where)
        body = s[1:-1]
        return re.sub(r'\\(["\\nt])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)
    if s[0] == "'":
        if not s.endswith("'") or len(s) < 2:
            raise ConfigError("%s: unterminated string" % where)
        return s[1:-1]
    if s[0] == "[":
        if not s.endswith("]"):
            raise ConfigError("%s: unterminated array" % where)
        inner = s[1:-1].strip()
        items, cur, q, depth = [], "", None, 0
        for c in inner:
            if q:
                cur += c
                if c == q:
                    q = None
                continue
            if c in "\"'":
                q = c
            elif c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
            if c == "," and depth == 0:
                if cur.strip():
                    items.append(_value(cur, where))
                cur = ""
                continue
            cur += c
        if cur.strip():
            items.append(_value(cur, where))
        return items
    if s in ("true", "false"):
        return s == "true"
    if re.fullmatch(r"[+-]?\d+", s.replace("_", "")):
        return int(s.replace("_", ""))
    if re.fullmatch(r"[+-]?\d+\.\d*([eE][+-]?\d+)?", s):
        return float(s)
    raise ConfigError("%s: unsupported value %r (quote strings)" % (where, s))


def parse_toml(text):
    if _tomllib is not None:
        try:
            return _tomllib.loads(text)
        except Exception as e:  # report the same way as the fallback parser
            raise ConfigError(str(e))
    root, cur = {}, None
    cur = root
    pending = ""
    for n, raw in enumerate(text.splitlines(), 1):
        line = _strip_comment(raw)
        if pending:
            line = pending + " " + line
            pending = ""
        if not line:
            continue
        m = re.fullmatch(r"\[\s*(" + _KEY + r"(?:\s*\.\s*" + _KEY + r")*)\s*\]", line)
        if m:
            cur = root
            for part in re.split(r"\s*\.\s*", m.group(1)):
                part = part.strip('"')
                cur = cur.setdefault(part, {})
                if not isinstance(cur, dict):
                    raise ConfigError("line %d: %s is not a table" % (n, part))
            continue
        m = re.fullmatch(r"(" + _KEY + r")\s*=\s*(.*)", line)
        if not m:
            raise ConfigError("line %d: cannot parse %r" % (n, raw.strip()))
        val = m.group(2)
        if val.strip().startswith("[") and val.count("[") > val.count("]"):
            pending = line  # multi-line array
            continue
        cur[m.group(1).strip('"')] = _value(val, "line %d" % n)
    if pending:
        raise ConfigError("unterminated multi-line array")
    return root


def _toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    s = str(v)
    if "'" not in s and ("\\" in s or '"' in s):
        return "'" + s + "'"
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def dump_toml(d, header=""):
    """Write a config dict back as TOML (top-level scalars first, then one table per section)."""
    lines = [header.rstrip()] if header else []
    for k, v in d.items():
        if not isinstance(v, dict):
            lines.append("%s = %s" % (k, _toml_value(v)))
    for k, v in d.items():
        if isinstance(v, dict):
            lines.append("")
            lines.append("[%s]" % k)
            for k2, v2 in v.items():
                if not isinstance(v2, dict):
                    lines.append("%s = %s" % (k2, _toml_value(v2)))
    return "\n".join(lines).strip() + "\n"


# ---------------------------------------------------------------- paths
def platform_name(plat=None):
    plat = plat or sys.platform
    if plat.startswith("win"):
        return "win32"
    if plat == "darwin":
        return "darwin"
    return "linux"


def config_path(env=None, plat=None):
    env = os.environ if env is None else env
    if env.get("FOREVERSCRIBE_CONFIG"):
        return env["FOREVERSCRIBE_CONFIG"]
    p = platform_name(plat)
    if p == "win32":
        base = env.get("APPDATA") or os.path.join(env.get("USERPROFILE", "~"), "AppData", "Roaming")
        return _join(p, base, "foreverscribe", "config.toml")
    base = env.get("XDG_CONFIG_HOME") or _join(p, _home(env), ".config")
    return _join(p, base, "foreverscribe", "config.toml")


def default_data_dir(env=None, plat=None):
    env = os.environ if env is None else env
    p = platform_name(plat)
    if p == "win32":
        base = env.get("LOCALAPPDATA") or os.path.join(env.get("USERPROFILE", "~"), "AppData", "Local")
        return _join(p, base, "foreverscribe")
    base = env.get("XDG_DATA_HOME") or _join(p, _home(env), ".local", "share")
    return _join(p, base, "foreverscribe")


def _home(env):
    return env.get("HOME") or env.get("USERPROFILE") or os.path.expanduser("~")


def _join(p, *parts):
    if p == "win32":
        return "\\".join(x.rstrip("\\/") for x in parts)
    return os.path.join(*parts)


def _expand(path, env=None):
    if not path:
        return path
    env = os.environ if env is None else env
    if path.startswith("~"):
        path = _home(env) + path[1:]
    return os.path.expandvars(path)


# ---------------------------------------------------------------- config object
def _merge(base, over):
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            _merge(base[k], v)
        else:
            base[k] = v
    return base


class Config(dict):
    """Merged config dict plus resolved paths (attributes)."""

    @property
    def data_dir(self):
        return self["_data_dir"]

    def path(self, *parts):
        return os.path.join(self.data_dir, *parts)

    @property
    def db(self):
        return os.environ.get("FOREVERSCRIBE_DB") or self.get("_db") or self.path("forever.db")

    @property
    def sources(self):
        if os.environ.get("FOREVERSCRIBE_SOURCES"):
            return os.environ["FOREVERSCRIBE_SOURCES"].split(os.pathsep)
        return self["_sources"]

    def section(self, name):
        return self.get(name) or {}


def load(path=None, env=None, plat=None):
    env = os.environ if env is None else env
    path = path or config_path(env, plat)
    cfg = copy.deepcopy(DEFAULTS)
    exists = os.path.exists(path)
    if exists:
        with open(path, encoding="utf-8") as fh:
            _merge(cfg, parse_toml(fh.read()))
    cfg = Config(cfg)
    cfg["_path"] = path
    cfg["_exists"] = exists
    data = _expand(cfg.get("data_dir") or env.get("FOREVERSCRIBE_DATA") or default_data_dir(env, plat), env)
    cfg["_data_dir"] = data
    cfg["_sources"] = resolve_sources(cfg, env, plat)
    return cfg


def wow_dir(cfg, env=None, plat=None):
    d = _expand((cfg.get("wow") or {}).get("dir") or "", env)
    if d:
        return d
    for c in WOW_CANDIDATES.get(platform_name(plat), []):
        c = _expand(c, env)
        if os.path.isdir(c):
            return c
    return ""


def resolve_sources(cfg, env=None, plat=None):
    """Folders/files the companion ingests on every query (cheap: unchanged files are skipped by hash)."""
    data = cfg["_data_dir"]
    out = [os.path.join(data, "push"), os.path.join(data, "pull")]
    wd = wow_dir(cfg, env, plat)
    mode = (cfg.get("transport") or {}).get("mode") or "local"
    if wd and mode == "local":
        accounts = (cfg.get("wow") or {}).get("accounts") or []
        base = os.path.join(wd, "WTF", "Account")
        if accounts:
            out += [os.path.join(base, a, "SavedVariables") for a in accounts]
            for a in accounts:  # per-character SavedVariables (Polestar's PolestarCharDB)
                out += sorted(glob.glob(os.path.join(base, a, "*", "*", "SavedVariables")))
        elif os.path.isdir(base):
            out += sorted(glob.glob(os.path.join(base, "*", "SavedVariables")))
            out += sorted(glob.glob(os.path.join(base, "*", "*", "*", "SavedVariables")))
    folder = _expand((cfg.get("transport") or {}).get("folder") or "", env)
    if folder:
        out.append(folder)
    for extra in (cfg.get("sources") or {}).get("extra") or []:
        out.append(_expand(extra, env))
    live = _expand((cfg.get("sources") or {}).get("live_dir") or "", env)
    if live:
        out.append(live)
    seen, res = set(), []
    for p in out:
        if p and p not in seen:
            seen.add(p)
            res.append(p)
    return res


def extra_sv_patterns(cfg):
    pats = (cfg.get("sync") or {}).get("extra_saved_variables")
    if pats is None:
        pats = DEFAULTS["sync"]["extra_saved_variables"]
    return [p for p in pats if p and "/" not in p and "\\" not in p]


def write(cfg_dict, path, header=""):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(dump_toml({k: v for k, v in cfg_dict.items() if not k.startswith("_")}, header))
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)
    return path
