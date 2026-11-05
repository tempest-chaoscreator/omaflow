#!/usr/bin/env python3
"""JSON-line client for coolercontrold on 127.0.0.1.

Speaks HTTP only to 127.0.0.1:11987. The password and the bearer token
are written only after the accepted socket is identified as coolercontrold.
Redirects are refused, so those credentials are not forwarded. The client
does not open sysfs, USB, or liquidctl. Sensor reads and fan writes stay
on the daemon's poll_rate (default 1 second). This client never changes
that setting.
"""

from __future__ import annotations

import base64
import errno
import fcntl
import http.client
import io
import json
import os
import re
import socket
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path

import lcd_logo

BASE = "http://127.0.0.1:11987"
_DAEMON_HOST = "127.0.0.1"
_DAEMON_PORT = 11987
_DAEMON_CGROUP = "/system.slice/coolercontrold.service"
_LISTENER_REJECTED = "listener on 127.0.0.1:11987 is not coolercontrold"
TOKEN_PATH = Path.home() / ".config" / "omaflow" / "coolercontrol.token"
GROUPS_PATH = TOKEN_PATH.with_name("groups.json")
LINKS_PATH = TOKEN_PATH.with_name("links.json")
HIDDEN_PATH = TOKEN_PATH.with_name("hidden.json")
LCD_VIEW_PATH = TOKEN_PATH.with_name("lcd-view.json")
LCD_LEASE_PATH = TOKEN_PATH.with_name("lcd-lease.json")
UI_PATH = TOKEN_PATH.with_name("ui.json")
PACK_PATH = TOKEN_PATH.with_name("curve-pack.json")
THEME_COLORS = Path.home() / ".local/state/omarchy/current/theme/colors.toml"
_TEXT_STOPS = {9, 10, 11, 12, 14, 16, 20}
_LCD_STOPS = {0, 2, 5, 10, 30, 60}
_LCD_FACES = ("liquid", "cpu", "cpu-gpu", "cpu-liquid", "omarchy", "omarchy-time", "picture")
_LOGO_FACES = ("omarchy", "omarchy-time")
_STILL_FACES = _LOGO_FACES + ("picture",)
_PICTURE_LIMIT = 20 * 1024 * 1024
# First look at a channel whose saved view never recorded Sync or Off.
_lcd_mode_cache: dict[str, str] = {}
_FILE_LIMIT = 1_000_000
_METHODS = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"}
_SSE_LIMIT = 1_000_000
# Factory password shipped by coolercontrold. Tried once, only when no token
# exists, and only against localhost. A changed password is left alone.
FACTORY_PASSWORD = "coolAdmin"
_OUT = threading.Lock()
_STOP = threading.Event()


def emit(obj: dict) -> None:
    line = json.dumps(obj, separators=(",", ":"))
    with _OUT:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("short write")
        view = view[written:]


def _nofollow_flags(base: int, nonblock: bool = False) -> int:
    """Refuse a symlink. Directory walks leave O_NONBLOCK off."""
    flags = base
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if nonblock and hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    return flags


def _write_private(path: Path, payload: bytes) -> None:
    """Create or replace a 0600 file. A symlink is left untouched."""
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = _nofollow_flags(os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    try:
        _write_all(fd, payload)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def _store_token(token: str) -> None:
    _write_private(TOKEN_PATH, (token + "\n").encode("utf-8"))


def _proc_addr(ip: str, port: int) -> str:
    """Address column of /proc/net/tcp. The kernel prints IPv4 little-endian."""
    raw = socket.inet_aton(ip)
    return raw[::-1].hex().upper() + ":%04X" % port


def _service_cgroup(path: str) -> bool:
    return path == _DAEMON_CGROUP or path.startswith(_DAEMON_CGROUP + "/")


def _trusted_peer(uid: int, cgroup: str | None, exe: str | None) -> bool:
    """Root must be the coolercontrold service. The same user must be that binary.

    Another account cannot own either socket. A copied binary run by this
    user is outside the attack the marketplace review described: that user
    can already read the mode 0600 token file.
    """
    if uid == 0:
        return _service_cgroup(cgroup or "")
    if uid != os.getuid() or not exe:
        return False
    return os.path.basename(exe) == "coolercontrold"


def _established_peer(local_port: int) -> tuple[int, str] | None:
    """Uid and inode of the socket that accepted this connection."""
    want_local = _proc_addr(_DAEMON_HOST, _DAEMON_PORT)
    want_remote = _proc_addr(_DAEMON_HOST, local_port)
    found: list[tuple[int, str]] = []
    try:
        lines = open("/proc/net/tcp", encoding="ascii", errors="replace")
    except OSError:
        return None
    with lines:
        next(lines, None)
        for line in lines:
            cols = line.split()
            if len(cols) < 10:
                continue
            if cols[1].upper() != want_local or cols[2].upper() != want_remote:
                continue
            if cols[3] != "01":
                continue
            try:
                uid = int(cols[7])
            except ValueError:
                continue
            found.append((uid, cols[9]))
    if len(found) != 1:
        return None
    return found[0]


def _socket_cgroup(local_port: int) -> tuple[str, str] | None:
    """Cgroup and inode of the daemon side of this TCP connection."""
    filt = "src %s:%d and dst %s:%d" % (_DAEMON_HOST, _DAEMON_PORT, _DAEMON_HOST, local_port)
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    try:
        out = subprocess.run(
            ["/usr/bin/ss", "-H", "-tnpe", filt],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    rows = [ln.strip() for ln in out.stdout.splitlines() if ln.strip()]
    if len(rows) != 1:
        return None
    cgroup = re.search(r"cgroup:(\S+)", rows[0])
    inode = re.search(r"\bino:(\d+)\b", rows[0])
    if not cgroup or not inode:
        return None
    return cgroup.group(1), inode.group(1)


def _exe_for_inode(inode: str) -> str | None:
    """Executable holding this socket. Unreadable processes are skipped."""
    needle = "socket:[%s]" % inode
    found: list[str] = []
    try:
        pids = os.listdir("/proc")
    except OSError:
        return None
    for pid in pids:
        if not pid.isdigit():
            continue
        fd_dir = "/proc/%s/fd" % pid
        try:
            fds = os.listdir(fd_dir)
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink("%s/%s" % (fd_dir, fd))
            except OSError:
                continue
            if target != needle:
                continue
            try:
                exe = os.readlink("/proc/%s/exe" % pid)
            except OSError:
                return None
            found.append(exe)
            break
    if len(found) != 1:
        return None
    return found[0]


def _daemon_process_present() -> bool:
    """The service cgroup must contain the coolercontrold binary."""
    proc_file = "/sys/fs/cgroup" + _DAEMON_CGROUP + "/cgroup.procs"
    try:
        with open(proc_file, encoding="ascii") as handle:
            pids = handle.read().split()
    except OSError:
        return False
    for pid in pids:
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as handle:
                raw = handle.read()
        except OSError:
            continue
        command = raw.split(b"\0", 1)[0].decode("utf-8", "replace")
        if os.path.basename(command) == "coolercontrold":
            return True
    return False


def _peer_trusted(sock: socket.socket) -> tuple[bool, str]:
    """Identify the process that accepted this socket. Fail closed."""
    try:
        local = sock.getsockname()
        peer = sock.getpeername()
    except OSError:
        return False, _LISTENER_REJECTED
    if sock.family != socket.AF_INET:
        return False, _LISTENER_REJECTED
    if local[0] != _DAEMON_HOST or peer != (_DAEMON_HOST, _DAEMON_PORT):
        return False, _LISTENER_REJECTED
    established = _established_peer(int(local[1]))
    if established is None:
        return False, "could not identify the listener"
    uid, inode = established
    if uid == 0:
        described = _socket_cgroup(int(local[1]))
        if described is None:
            return False, _LISTENER_REJECTED
        try:
            same_socket = int(described[1]) == int(inode)
        except ValueError:
            same_socket = False
        if not same_socket or not _trusted_peer(uid, described[0], None):
            return False, _LISTENER_REJECTED
        if not _daemon_process_present():
            return False, _LISTENER_REJECTED
        return True, ""
    if uid == os.getuid() and _trusted_peer(uid, None, _exe_for_inode(inode)):
        return True, ""
    return False, _LISTENER_REJECTED


class _DaemonConnection(http.client.HTTPConnection):
    """Loopback connection that stays silent until the peer is coolercontrold."""

    def connect(self) -> None:
        if self.host != _DAEMON_HOST or int(self.port or 0) != _DAEMON_PORT:
            raise OSError("coolercontrold address is fixed")
        raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            raw.settimeout(self.timeout)
            raw.bind((_DAEMON_HOST, 0))
            raw.connect((_DAEMON_HOST, _DAEMON_PORT))
            ok, reason = _peer_trusted(raw)
            if not ok:
                raise OSError(reason or _LISTENER_REJECTED)
            try:
                raw.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError as err:
                if err.errno != errno.ENOPROTOOPT:
                    raise
        except Exception:
            raw.close()
            raise
        self.sock = raw


class _DaemonHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        parsed = urllib.parse.urlsplit(req.full_url)
        if parsed.scheme != "http" or parsed.hostname != _DAEMON_HOST or parsed.port != _DAEMON_PORT:
            raise urllib.error.URLError("coolercontrold address is fixed")
        return self.do_open(_DaemonConnection, req)


class _RefuseRedirect(urllib.request.HTTPRedirectHandler):
    """A 3xx must not carry the password, the token, or the session cookie."""

    def http_error_302(self, req, fp, code, msg, headers):
        try:
            fp.read(65536)
        except Exception:
            pass
        try:
            fp.close()
        except Exception:
            pass
        raise urllib.error.HTTPError(
            req.full_url,
            code,
            "redirect refused",
            headers,
            io.BytesIO(b""),
        )

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


def _daemon_opener(jar: CookieJar | None = None) -> urllib.request.OpenerDirector:
    # Passing a ProxyHandler suppresses the default one. An empty mapping
    # installs no proxy methods, so http_proxy cannot receive the token.
    handlers: list = [
        urllib.request.ProxyHandler({}),
        _DaemonHTTPHandler(),
        _RefuseRedirect(),
    ]
    if jar is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(jar))
    return urllib.request.build_opener(*handlers)


_DAEMON_OPENER: urllib.request.OpenerDirector | None = None


def _open(req: urllib.request.Request, timeout: float | None, jar: CookieJar | None = None):
    # Pairing carries a cookie jar and stays on its own opener. Every other
    # call shares one. Each connection still identifies the listener.
    if jar is not None:
        return _daemon_opener(jar).open(req, timeout=timeout)
    global _DAEMON_OPENER
    if _DAEMON_OPENER is None:
        _DAEMON_OPENER = _daemon_opener(None)
    return _DAEMON_OPENER.open(req, timeout=timeout)


def pair(password: str) -> dict:
    """Log in once, mint a revocable Omaflow token, forget the password."""
    if BASE != "http://127.0.0.1:11987":
        return {"ok": False, "status": 0, "error": "pairing is localhost-only", "body": None}
    if not password:
        return {"ok": False, "status": 0, "error": "password required", "body": None}
    jar = CookieJar()
    opener = _daemon_opener(jar)
    basic = base64.b64encode(b"CCAdmin:" + password.encode("utf-8")).decode("ascii")
    login = urllib.request.Request(
        BASE + "/login",
        method="POST",
        headers={"Authorization": "Basic " + basic},
    )
    try:
        opener.open(login, timeout=8).read()
    except urllib.error.HTTPError as err:
        if err.code in (301, 302, 303, 307, 308):
            return {"ok": False, "status": err.code, "error": "redirect refused", "body": None}
        return {"ok": False, "status": 401, "error": "CoolerControl rejected that password", "body": None}
    except urllib.error.URLError as err:
        return {"ok": False, "status": 0, "error": str(err.reason), "body": None}
    body = json.dumps({"label": "Omaflow", "expires_at": None, "write_access": True}).encode("utf-8")
    create = urllib.request.Request(
        BASE + "/tokens",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with opener.open(create, timeout=8) as res:
            payload = json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        if err.code in (301, 302, 303, 307, 308):
            return {"ok": False, "status": err.code, "error": "redirect refused", "body": None}
        return {"ok": False, "status": err.code, "error": "Could not create an access token", "body": None}
    except urllib.error.URLError as err:
        return {"ok": False, "status": 0, "error": str(err.reason), "body": None}
    token = str(payload.get("token") or "")
    if not token.startswith("cc_"):
        return {"ok": False, "status": 0, "error": "Daemon did not return a token", "body": None}
    _store_token(token)
    return {"ok": True, "status": 200, "error": "", "body": None}


def _plain_label(value: object, fallback: str) -> str:
    """Same rule as qml/CcMap.js plainLabel. A tag anywhere in the line is rich text."""
    text = "".join(
        ch for ch in str("" if value is None else value)
        if ch >= " " and ch != "\x7f"
    ).strip()
    if not text or len(text) > 120 or "<" in text or ">" in text:
        return fallback
    return text


def _clean_groups(groups: object) -> list:
    if not isinstance(groups, list):
        return []
    clean = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        nxt = dict(group)
        nxt["name"] = _plain_label(group.get("name"), "Group")
        clean.append(nxt)
    return clean


def _read_json(path: Path) -> object | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def read_groups() -> dict:
    data = _read_json(GROUPS_PATH)
    if not isinstance(data, dict) or not isinstance(data.get("groups"), list):
        return {"groups": []}
    return {"groups": _clean_groups(data.get("groups"))}


def write_groups(data: dict) -> None:
    payload = json.dumps(
        {"groups": _clean_groups(data.get("groups") if isinstance(data, dict) else None)},
        indent=2,
    ).encode("utf-8")
    _write_private(GROUPS_PATH, payload)


def read_links() -> dict:
    """Per-card curve link flags. Missing keys use the app defaults."""
    data = _read_json(LINKS_PATH)
    raw = data.get("links") if isinstance(data, dict) else None
    if not isinstance(raw, dict):
        return {"links": {}}
    clean = {}
    examined = 0
    for key, value in raw.items():
        examined += 1
        if examined > 200:
            break
        if not isinstance(key, str) or len(key) > 80:
            continue
        if isinstance(value, bool):
            clean[key] = value
    return {"links": clean}


def _clean_hidden(raw: object) -> dict:
    """Device uids the user hid. Absent means shown."""
    if not isinstance(raw, dict):
        return {}
    clean = {}
    examined = 0
    for key, value in raw.items():
        examined += 1
        if examined > 200:
            break
        if not isinstance(key, str) or not key or len(key) > 80:
            continue
        if value is True:
            clean[key] = True
    return clean


def read_hidden() -> dict:
    data = _read_json(HIDDEN_PATH)
    raw = data.get("devices") if isinstance(data, dict) else None
    return {"devices": _clean_hidden(raw)}


def write_hidden(data: dict) -> None:
    raw = data.get("devices") if isinstance(data, dict) else None
    payload = json.dumps({"devices": _clean_hidden(raw)}, indent=2).encode("utf-8")
    _write_private(HIDDEN_PATH, payload)


def _lcd_seconds(value: object) -> int:
    try:
        seconds = int(str(value))
    except (TypeError, ValueError):
        return 5
    return seconds if seconds in _LCD_STOPS else 5


def _ui_text(value: object, limit: int) -> str:
    text = str(value or "").replace("\n", "").replace("\r", "").replace("\x00", "")
    if len(text) > limit:
        return ""
    return text


def _ui_binds(raw: object) -> list:
    """Silent-ramp undo records. A bad or huge list is dropped, not applied."""
    if not isinstance(raw, list):
        return []
    out: list[dict] = []
    for row in raw[:128]:
        if not isinstance(row, dict):
            continue
        device = _ui_text(row.get("deviceUid"), 80)
        channel = _ui_text(row.get("channel"), 80)
        profile = _ui_text(row.get("profileUid"), 80)
        clone = _ui_text(row.get("cloneUid"), 80)
        prev = _ui_text(row.get("prevFunction"), 80)
        if any(ch in device + channel for ch in ("/", "?", "#", "\\")):
            continue
        if not device and not channel and not profile and not clone:
            continue
        out.append({
            "deviceUid": device,
            "channel": channel,
            "profileUid": profile,
            "cloneUid": clone,
            "prevFunction": prev or "0",
        })
    return out


def _ui_from(raw: dict) -> dict:
    try:
        size = int(raw.get("textSize"))
    except (TypeError, ValueError):
        size = 12
    if size not in _TEXT_STOPS:
        size = 12
    return {
        "dynamicScale": raw.get("dynamicScale") is True,
        "pinGroups": raw.get("pinGroups") is True,
        "textFollow": raw.get("textFollow") is not False,
        "textSize": size,
        # Absent means on. Only an explicit false keeps the chip off.
        "showBar": raw.get("showBar") is not False,
        "lcdBackground": raw.get("lcdBackground") is not False,
        "lcdSeconds": _lcd_seconds(raw.get("lcdSeconds")),
        "lcdThemeSync": raw.get("lcdThemeSync") is True,
        # Absent means the 50% pump floor stays on.
        "pumpFloor": raw.get("pumpFloor") is not False,
        "silentRamp": raw.get("silentRamp") is True,
        "silentRampUid": _ui_text(raw.get("silentRampUid"), 80),
        "silentRampBinds": _ui_binds(raw.get("silentRampBinds")),
    }


def read_ui() -> dict:
    default = _ui_from({})
    raw = _read_json(UI_PATH)
    if not isinstance(raw, dict):
        return default
    return _ui_from(raw)


def _copy_ui_flags(clean: dict, data: dict, keys: tuple[str, ...], exact_true: bool) -> None:
    """Copy flags that are present in this patch. Absent keys stay as read_ui left them.

    exact_true stores only a real true. The other flags stay on for every value except false.
    """
    for key in keys:
        if key not in data:
            continue
        clean[key] = data.get(key) is True if exact_true else data.get(key) is not False


def write_ui(data: dict) -> None:
    clean = read_ui()
    if isinstance(data, dict):
        _copy_ui_flags(clean, data, ("dynamicScale", "pinGroups", "lcdThemeSync", "silentRamp"), True)
        _copy_ui_flags(clean, data, ("textFollow", "showBar", "lcdBackground", "pumpFloor"), False)
        if "textSize" in data:
            try:
                size = int(data.get("textSize"))
            except (TypeError, ValueError):
                size = clean["textSize"]
            if size in _TEXT_STOPS:
                clean["textSize"] = size
        if "lcdSeconds" in data:
            clean["lcdSeconds"] = _lcd_seconds(data.get("lcdSeconds"))
        if "silentRampUid" in data:
            clean["silentRampUid"] = _ui_text(data.get("silentRampUid"), 80)
        if "silentRampBinds" in data:
            clean["silentRampBinds"] = _ui_binds(data.get("silentRampBinds"))
    _write_private(UI_PATH, json.dumps(clean, indent=2).encode("utf-8"))


# Same caps as qml/CcMap.js. A JSON object with a huge length is not a list.
# The 1 MB file cap does not stop that object from freezing the shell.
_PACK_MODE_CAP = 64
_PACK_CHANNEL_CAP = 128
_PACK_POINT_CAP = 64
_PACK_GROUP_CAP = 64
_PACK_MEMBER_CAP = 128


def _bounded_list(value: object, cap: int) -> list | None:
    if not isinstance(value, list) or len(value) > cap:
        return None
    return value


def valid_curve_pack(data: object) -> bool:
    if not isinstance(data, dict) or data.get("kind") != "omaflow-curves" or data.get("version") != 1:
        return False
    if isinstance(data.get("version"), bool):
        return False
    modes = _bounded_list(data.get("modes"), _PACK_MODE_CAP)
    if modes is None:
        return False
    for mode in modes:
        if not isinstance(mode, dict):
            return False
        if "channels" not in mode or mode.get("channels") is None:
            continue
        channels = _bounded_list(mode.get("channels"), _PACK_CHANNEL_CAP)
        if channels is None:
            return False
        for row in channels:
            if not isinstance(row, dict):
                return False
            if "points" not in row or row.get("points") is None:
                continue
            if _bounded_list(row.get("points"), _PACK_POINT_CAP) is None:
                return False
    if "groups" not in data or data.get("groups") is None:
        return True
    groups = _bounded_list(data.get("groups"), _PACK_GROUP_CAP)
    if groups is None:
        return False
    for group in groups:
        if not isinstance(group, dict):
            return False
        if "members" not in group or group.get("members") is None:
            continue
        if _bounded_list(group.get("members"), _PACK_MEMBER_CAP) is None:
            return False
    return True


def read_pack() -> dict:
    raw = _read_json(PACK_PATH)
    if not valid_curve_pack(raw):
        return {}
    return raw


def write_pack(data: dict) -> None:
    if not valid_curve_pack(data):
        raise ValueError("not an omaflow curve pack")
    payload = json.dumps(data, indent=2).encode("utf-8")
    if len(payload) > _FILE_LIMIT:
        raise ValueError("curve pack is too large")
    _write_private(PACK_PATH, payload)


def clear_pack() -> None:
    try:
        PACK_PATH.unlink()
    except OSError:
        pass


def _user_target(path_text: str) -> Path | None:
    """A regular file under the home directory. No symlink escape."""
    home = Path.home().resolve()
    raw = Path(str(path_text or "")).expanduser()
    if not raw.is_absolute():
        raw = home / raw
    if raw.name.startswith(".") or not raw.name or len(raw.name) > 180:
        return None
    if raw.suffix.lower() != ".json":
        return None
    parent = raw.parent
    try:
        parent_resolved = parent.resolve()
    except OSError:
        return None
    if parent_resolved != home and home not in parent_resolved.parents:
        return None
    if parent.is_symlink():
        return None
    return parent_resolved / raw.name


def read_user_json(path_text: str) -> dict:
    target = _user_target(path_text)
    if target is None:
        return {"ok": False, "status": 400, "error": "Choose a .json file inside your home directory", "body": None}
    try:
        if not target.is_file() or target.is_symlink():
            return {"ok": False, "status": 400, "error": "That file is not there", "body": None}
        if target.stat().st_size > _FILE_LIMIT:
            return {"ok": False, "status": 400, "error": "That file is too large", "body": None}
        body = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"ok": False, "status": 400, "error": "That file is not readable JSON", "body": None}
    if not isinstance(body, dict):
        return {"ok": False, "status": 400, "error": "That file is not a curve pack", "body": None}
    return {"ok": True, "status": 200, "error": "", "body": body}


def write_user_json(path_text: str, body: dict) -> dict:
    target = _user_target(path_text)
    if target is None:
        return {"ok": False, "status": 400, "error": "Choose a .json file inside your home directory", "body": None}
    if not isinstance(body, dict):
        return {"ok": False, "status": 400, "error": "Nothing to write", "body": None}
    payload = json.dumps(body, indent=2).encode("utf-8")
    if len(payload) > _FILE_LIMIT:
        return {"ok": False, "status": 400, "error": "Curve pack is too large", "body": None}
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        _write_private(target, payload)
    except OSError as err:
        return {"ok": False, "status": 400, "error": str(err), "body": None}
    return {"ok": True, "status": 200, "error": "", "body": {"path": str(target)}}


def write_links(data: dict) -> None:
    raw = data.get("links") if isinstance(data, dict) else None
    if not isinstance(raw, dict):
        raw = {}
    clean = {}
    examined = 0
    for key, value in raw.items():
        examined += 1
        if examined > 200:
            break
        if not isinstance(key, str) or len(key) > 80:
            continue
        if isinstance(value, bool):
            clean[key] = value
    _write_private(LINKS_PATH, json.dumps({"links": clean}, indent=2).encode("utf-8"))


def read_token() -> str:
    try:
        return TOKEN_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _parse_hex(value: str) -> tuple[int, int, int]:
    text = str(value or "").strip().lstrip("#")
    if len(text) == 3:
        text = "".join(ch * 2 for ch in text)
    if len(text) != 6:
        return (140, 180, 255)
    try:
        return (int(text[0:2], 16), int(text[2:4], 16), int(text[4:6], 16))
    except ValueError:
        return (140, 180, 255)


def _lcd_font(size: int):
    from PIL import ImageFont
    for path in (
        "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Bold.ttf",
        "/usr/share/fonts/TTF/JetBrainsMono-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    ):
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


_LCD_BG = (10, 12, 11)


def _face_labels(face: str) -> tuple[str, str]:
    if face == "cpu":
        return ("CPU", "")
    if face == "cpu-gpu":
        return ("CPU", "GPU")
    if face == "cpu-liquid":
        return ("CPU", "LIQUID")
    return ("LIQUID", "")


def _draw_at(draw, cx: float, y: float, text: str, font, fill) -> None:
    box = draw.textbbox((0, 0), text, font=font)
    width = box[2] - box[0]
    draw.text(
        (cx - width / 2 - box[0], y - box[1]),
        text,
        font=font,
        fill=fill,
        stroke_width=2,
        stroke_fill=(0, 0, 0),
    )


def _paint_readings(draw, width: float, height: float, scale: float, combo: bool, number: str, other: str, left: str, right: str, ink, ink2) -> None:
    """Shared type for the round glass and the square panel. Positions stay proportional."""
    if combo:
        number_font = _lcd_font(max(12, int(round(78 * scale))))
        label_font = _lcd_font(max(10, int(round(22 * scale))))
        _draw_at(draw, width * 0.34, height * 0.40, number, number_font, ink)
        _draw_at(draw, width * 0.66, height * 0.40, other, number_font, ink2)
        _draw_at(draw, width * 0.34, height * 0.62, left, label_font, ink)
        _draw_at(draw, width * 0.66, height * 0.62, right, label_font, ink2)
        draw.line(
            [(width / 2, height * 0.34), (width / 2, height * 0.70)],
            fill=(250, 252, 251),
            width=max(1, int(round(2 * scale))),
        )
        return
    number_font = _lcd_font(max(16, int(round(104 * scale))))
    label_font = _lcd_font(max(10, int(round(26 * scale))))
    _draw_at(draw, width / 2, height * 0.36, number, number_font, ink)
    _draw_at(draw, width / 2, height * 0.62, left, label_font, ink)


def _plate(face: str, primary: str, secondary: str, accent: str, accent2: str, width: int, height: int):
    """Ink, stroke, and the two readings. Both plates scale from the 320 design."""
    ink = _parse_hex(accent)
    ink2 = _parse_hex(accent2 or accent)
    scale = min(width, height) / 320
    margin = max(8, int(round(22 * scale)))
    stroke = max(4, int(round(14 * scale)))
    combo = face in ("cpu-gpu", "cpu-liquid")
    left, right = _face_labels(face)
    number = primary if primary else "—"
    other = secondary if secondary else "—"
    return ink, ink2, scale, margin, stroke, combo, number, other, left, right


def _render_round(face: str, primary: str, secondary: str, accent: str, accent2: str, angle: int, size: int) -> bytes:
    """Upright frame, then turned clockwise by `angle`. The daemon orientation stays 0."""
    from PIL import Image, ImageDraw
    image = Image.new("RGB", (size, size), _LCD_BG)
    draw = ImageDraw.Draw(image)
    ink, ink2, scale, margin, stroke, combo, number, other, left, right = _plate(
        face, primary, secondary, accent, accent2, size, size,
    )
    box = [margin, margin, size - margin - 1, size - margin - 1]
    if combo:
        # Pillow measures arcs clockwise from 3 o'clock. Left half, then right half.
        draw.arc(box, start=90, end=270, fill=ink, width=stroke)
        draw.arc(box, start=270, end=90, fill=ink2, width=stroke)
    else:
        draw.ellipse(box, outline=ink, width=stroke)
    _paint_readings(draw, size, size, scale, combo, number, other, left, right, ink, ink2)
    return lcd_logo.bake_png(image, angle, _LCD_BG)


def _render_square(face: str, primary: str, secondary: str, accent: str, accent2: str, angle: int, width: int, height: int) -> bytes:
    """Square-panel frame. Rotation stays inside the reported pixel buffer."""
    from PIL import Image, ImageDraw
    image = Image.new("RGB", (width, height), _LCD_BG)
    draw = ImageDraw.Draw(image)
    ink, ink2, scale, margin, stroke, combo, number, other, left, right = _plate(
        face, primary, secondary, accent, accent2, width, height,
    )
    right_edge = width - margin - 1
    bottom = height - margin - 1
    draw.rectangle([margin, margin, right_edge, bottom], outline=ink, width=stroke)
    if combo:
        mid = width / 2
        draw.line([(mid, margin), (right_edge, margin)], fill=ink2, width=stroke)
        draw.line([(right_edge, margin), (right_edge, bottom)], fill=ink2, width=stroke)
        draw.line([(mid, bottom), (right_edge, bottom)], fill=ink2, width=stroke)
    _paint_readings(draw, width, height, scale, combo, number, other, left, right, ink, ink2)
    return lcd_logo.bake_png(image, angle, _LCD_BG)


def _lcd_view() -> dict | None:
    view = _read_json(LCD_VIEW_PATH)
    return view if isinstance(view, dict) else None


def _bound_int(value: object, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return max(0, min(100, number))


def _picture_path_from_view() -> str:
    view = _lcd_view()
    if view is None:
        return ""
    return str(view.get("picture") or "")


def _picture_fd(raw: object) -> tuple[int, str] | None:
    """Open one regular image under the home directory. A symlink is refused.

    The walk opens each directory with O_NOFOLLOW, so a link in the middle
    cannot point the read outside home. The caller closes the file descriptor.
    """
    text = str(raw or "").strip()
    if not text or len(text) > 4096 or "\x00" in text or not text.startswith("/"):
        return None
    path = Path(text)
    if ".." in path.parts:
        return None
    try:
        home = Path.home().resolve()
        rel = path.relative_to(home)
    except (OSError, ValueError):
        return None
    if not rel.parts:
        return None
    dir_flags = _nofollow_flags(os.O_RDONLY | os.O_DIRECTORY)
    file_flags = _nofollow_flags(os.O_RDONLY, True)
    try:
        dir_fd = os.open(home, dir_flags)
    except OSError:
        return None
    fd = -1
    try:
        for part in rel.parts[:-1]:
            if part in ("", ".", ".."):
                return None
            nxt = os.open(part, dir_flags, dir_fd=dir_fd)
            os.close(dir_fd)
            dir_fd = nxt
        leaf = rel.parts[-1]
        if leaf in ("", ".", ".."):
            return None
        fd = os.open(leaf, file_flags, dir_fd=dir_fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0 or info.st_size > _PICTURE_LIMIT:
            os.close(fd)
            return None
        ident = "%s:%s:%s" % (getattr(info, "st_mtime_ns", int(info.st_mtime)), info.st_size, path)
        return fd, ident
    except OSError:
        if fd >= 0:
            os.close(fd)
        return None
    finally:
        try:
            os.close(dir_fd)
        except OSError:
            pass


def _load_picture(raw: object) -> tuple[bytes, str] | None:
    opened = _picture_fd(raw)
    if not opened:
        return None
    fd, ident = opened
    try:
        info = os.fstat(fd)
        blob = bytearray()
        while len(blob) < info.st_size:
            chunk = os.read(fd, min(1024 * 1024, info.st_size - len(blob)))
            if not chunk:
                break
            blob.extend(chunk)
        if len(blob) != info.st_size:
            return None
        return bytes(blob), ident
    except OSError:
        return None
    finally:
        os.close(fd)


def _picture_scale(value: object) -> int:
    """100 fits the image. Smaller leaves a margin. Larger crops from the center."""
    try:
        number = int(value)
    except (TypeError, ValueError):
        return 100
    return max(50, min(300, number))


def _render_picture_png(blob: bytes, width: int, height: int, shape: str, angle: int, scale_pct: int = 100) -> bytes:
    """Place the image on the AIO LCD, centered. Round glass is masked. The dial angle is baked in."""
    from PIL import Image, ImageDraw

    Image.MAX_IMAGE_PIXELS = 24_000_000
    src = Image.open(io.BytesIO(blob))
    try:
        try:
            src.seek(0)
        except EOFError:
            pass
        frame = src.convert("RGB")
    finally:
        src.close()
    w = max(32, min(1280, int(width or 320)))
    h = max(32, min(1280, int(height or 320)))
    fit = min(w / max(1, frame.width), h / max(1, frame.height))
    scale = fit * (_picture_scale(scale_pct) / 100)
    fitted = frame.resize(
        (max(1, int(round(frame.width * scale))), max(1, int(round(frame.height * scale)))),
        Image.Resampling.LANCZOS,
    )
    frame.close()
    canvas = Image.new("RGB", (w, h), _LCD_BG)
    canvas.paste(fitted, ((w - fitted.width) // 2, (h - fitted.height) // 2))
    fitted.close()
    if str(shape or "round") != "square":
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, w - 1, h - 1), fill=255)
        masked = Image.new("RGB", (w, h), _LCD_BG)
        masked.paste(canvas, mask=mask)
        canvas.close()
        mask.close()
        canvas = masked
    return lcd_logo.bake_png(canvas, angle, _LCD_BG, optimize=True)


def render_picture_png(path: str, width: int, height: int, shape: str, angle: int, scale: object = None) -> tuple[bytes, str] | None:
    loaded = _load_picture(path)
    if not loaded:
        return None
    blob, ident = loaded
    try:
        return _render_picture_png(blob, width, height, shape, angle, _picture_scale(scale)), ident
    except Exception as err:  # noqa: BLE001 — a bad image must not stop the helper
        sys.stderr.write("omaflow lcd picture: %s\n" % type(err).__name__)
        sys.stderr.flush()
        return None


def render_lcd_png(
    face: str,
    primary: str,
    secondary: str,
    accent: str,
    accent2: str,
    angle: int,
    size: int = 320,
    shape: str = "round",
    width: int | None = None,
    height: int | None = None,
) -> bytes:
    """Round glass stays a circle. Square panels use the reported pixel size."""
    side = max(32, min(1280, int(size or 320)))
    w = max(32, min(1280, int(width))) if width else side
    h = max(32, min(1280, int(height))) if height else side
    if face in _LOGO_FACES:
        theme_accent, _second, _background, _foreground = _theme_fields()
        lit = accent if re.fullmatch(r"#[0-9A-Fa-f]{6}", str(accent or "")) else (theme_accent or "#b59790")
        return lcd_logo.render_logo_png(
            face,
            lit or "#b59790",
            w,
            h,
            "square" if str(shape or "round") == "square" else "round",
            int(angle or 0),
        )
    if str(shape or "round") != "square":
        if w == h:
            return _render_round(face, primary, secondary, accent, accent2, angle, w)
        tile = _render_round(face, primary, secondary, accent, accent2, angle, min(w, h))
        from PIL import Image
        base = Image.new("RGB", (w, h), _LCD_BG)
        glyph = Image.open(io.BytesIO(tile))
        base.paste(glyph, ((w - glyph.width) // 2, (h - glyph.height) // 2))
        glyph.close()
        return lcd_logo.bake_png(base, 0, _LCD_BG)
    return _render_square(face, primary, secondary, accent, accent2, angle, w, h)


def _multipart(fields: list[tuple[str, str]], filename: str, payload: bytes) -> tuple[bytes, str]:
    boundary = "omaflow" + os.urandom(8).hex()
    chunks: list[bytes] = []
    for name, value in fields:
        chunks.append(
            (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode("utf-8")
        )
    chunks.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="images[]"; filename="{filename}"\r\n'
            f"Content-Type: image/png\r\n\r\n"
        ).encode("utf-8")
    )
    chunks.append(payload)
    chunks.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    return b"".join(chunks), "multipart/form-data; boundary=" + boundary


def _lcd_mark(
    shape: str,
    width: int,
    height: int,
    face: str,
    primary: str,
    secondary: str,
    ink: str,
    ink2: str,
    brightness: int,
    angle: int,
) -> str:
    return "|".join(
        [
            shape,
            "%sx%s" % (width, height),
            face,
            primary,
            secondary,
            ink,
            ink2,
            str(brightness),
            str(angle),
        ]
    )


def _upload_mark(
    shape: str,
    width: int,
    height: int,
    face: str,
    accent: str,
    accent2: str,
    primary: str,
    secondary: str,
    brightness: int,
    angle: int,
    picture_id: str = "",
    picture_scale: object = None,
) -> str:
    """The lease key. Logo faces ignore temperatures. The clock changes once a minute.

    A picture's second field is the zoom. The file identity alone would treat
    two sizes of the same file as the plate already on the cooler.
    """
    if face == "picture":
        return _lcd_mark(
            shape, width, height, face, picture_id, str(_picture_scale(picture_scale)),
            "", "", brightness, angle,
        )
    if face in _LOGO_FACES:
        theme_accent, _second, _background, _foreground = _theme_fields()
        lit = accent if re.fullmatch(r"#[0-9A-Fa-f]{6}", str(accent or "")) else (theme_accent or "#b59790")
        # The field is the temperature-face black. The clock uses that same accent, so the
        # theme background and foreground are not part of the plate.
        field = "#%02x%02x%02x" % _LCD_BG
        minute = time.strftime("%H:%M") if face == "omarchy-time" else ""
        return _lcd_mark(
            shape, width, height, face, minute, field, lit or "#b59790", "", brightness, angle,
        )
    return _lcd_mark(
        shape, width, height, face, primary, secondary, accent, accent2, brightness, angle,
    )


def _with_lcd_lease(update):
    """Exclusive access to the one-writer stamp shared by the window and the plugin.

    A symlink is left untouched. Anything that is not a regular file is ignored,
    so a replaced lease cannot block the helper or be followed.
    """
    try:
        LCD_LEASE_PATH.parent.mkdir(parents=True, exist_ok=True)
        flags = _nofollow_flags(os.O_RDWR | os.O_CREAT, True)
        fd = os.open(LCD_LEASE_PATH, flags, 0o600)
    except OSError:
        return {}
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return {}
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            os.fchmod(fd, 0o600)
        except OSError:
            pass
        blob = b""
        while len(blob) < 16384:
            chunk = os.read(fd, min(4096, 16384 - len(blob)))
            if not chunk:
                break
            blob += chunk
        prev: dict = {}
        try:
            parsed = json.loads(blob.decode("utf-8") or "{}")
            if isinstance(parsed, dict):
                prev = parsed
        except json.JSONDecodeError:
            prev = {}
        nxt = update(prev)
        if nxt is not None:
            raw = json.dumps(nxt).encode("utf-8")
            os.lseek(fd, 0, os.SEEK_SET)
            os.ftruncate(fd, 0)
            _write_all(fd, raw)
        return prev
    except OSError:
        return {}
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


def lcd_claim(mark: str, interval: float) -> bool:
    """True when this picture is not already on its way from the other process."""
    now = time.time()
    window = max(1.0, float(interval)) * 0.75
    decision = {"go": False}

    def update(prev: dict):
        try:
            prev_at = float(prev.get("at") or 0)
        except (TypeError, ValueError):
            prev_at = 0.0
        # A backward clock step makes the age negative. That stamp is stale.
        age = now - prev_at
        if str(prev.get("mark") or "") == mark and age >= 0 and age < window:
            decision["go"] = False
            return None
        decision["go"] = True
        return {"mark": mark, "at": now}

    _with_lcd_lease(update)
    return bool(decision["go"])


def lcd_remember(mark: str) -> None:
    now = time.time()

    def update(prev: dict):
        return {"mark": mark, "at": now}

    _with_lcd_lease(update)


def lcd_release(mark: str) -> None:
    def update(prev: dict):
        if str(prev.get("mark") or "") != mark:
            return None
        return {"mark": "", "at": 0}

    _with_lcd_lease(update)


def lcd_current_mark() -> str:
    prev = _with_lcd_lease(lambda _prev: None)
    if isinstance(prev, dict):
        return str(prev.get("mark") or "")
    return ""


def detect_shape(device_name: str, width: int, height: int) -> str:
    """Round or square from the cooler. A saved override is not consulted.

    Equal buffers need the name: 240 square panels and 320 or 640 round glass
    report the same kind of square pixel size. Unequal sides are square.
    """
    blob = str(device_name or "").lower()
    if re.search(r"ryujin|coreliquid", blob):
        return "square"
    if "kraken" in blob and re.search(r"2023|2024", blob) and "elite" not in blob:
        return "square"
    if width > 0 and height > 0 and width != height:
        return "square"
    return "round"


def _lcd_dim(value: object) -> int:
    try:
        number = int(str(value))
    except (TypeError, ValueError):
        return 0
    if number < 0 or number > 1280:
        return 0
    return number


def _face_text(face: str, cpu: object, gpu: object, coolant: object) -> tuple[str, str]:
    if face in _STILL_FACES:
        return "", ""
    if face in ("cpu", "cpu-gpu", "cpu-liquid"):
        primary = _whole(cpu)
    else:
        primary = _whole(coolant)
    secondary = ""
    if face == "cpu-gpu":
        secondary = _whole(gpu)
    elif face == "cpu-liquid":
        secondary = _whole(coolant)
    return primary, secondary


def _channel_lcd_mode(device: str, channel: str) -> str | None:
    path = (
        "/devices/"
        + urllib.parse.quote(device, safe="")
        + "/settings"
    )
    result = call("GET", path, None)
    if not result.get("ok"):
        return None
    body = result.get("body") if isinstance(result.get("body"), dict) else {}
    rows = body.get("settings") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        return None
    for row in rows:
        if not isinstance(row, dict) or str(row.get("channel_name") or "") != channel:
            continue
        lcd = row.get("lcd")
        if isinstance(lcd, dict):
            return str(lcd.get("mode") or "")
        return ""
    return ""


def _view_is_live(view: dict, device: str, channel: str) -> bool | None:
    """False leaves a cooler that is off, or one still on a built-in face, alone."""
    if "live" in view:
        return view.get("live") is True
    key = device + "/" + channel
    if key not in _lcd_mode_cache:
        mode = _channel_lcd_mode(device, channel)
        if mode is None:
            return None
        _lcd_mode_cache[key] = mode
    return _lcd_mode_cache[key] == "image"


def _lcd_skip(reason: str) -> dict:
    return {"ok": True, "status": 200, "error": "", "body": {"skipped": True, "reason": reason}}


def lcd_keep(msg: dict) -> dict:
    """Draw the saved pump face again when the numbers changed.

    The window and the bar plugin both call this. The lease keeps one upload.
    """
    if read_ui().get("lcdBackground") is False:
        return _lcd_skip("background-off")
    view = _lcd_view()
    if view is None:
        return _lcd_skip("no-view")
    device = str(msg.get("device") or "")
    channel = str(msg.get("channel") or "")
    if not device or not channel or len(device) > 80 or len(channel) > 80:
        return _lcd_skip("no-channel")
    if any(ch in device or ch in channel for ch in ("/", "?", "#", "\\", "\n", "\r")):
        return _lcd_skip("no-channel")
    live = _view_is_live(view, device, channel)
    if live is None:
        return _lcd_skip("unknown")
    if not live:
        return _lcd_skip("lcd-off")
    face = str(view.get("face") or "liquid")
    # An unknown face is left alone. Substituting Liquid is what painted over
    # a picture this helper did not know how to draw.
    if face not in _LCD_FACES:
        return _lcd_skip("other-face")
    brightness = _bound_int(view.get("brightness"), 80)
    saturation = _bound_int(view.get("saturation"), 0)
    try:
        angle = int(view.get("angle") or 0)
    except (TypeError, ValueError):
        angle = 0
    angle = angle % 360
    width = _lcd_dim(msg.get("width"))
    height = _lcd_dim(msg.get("height"))
    device_name = str(msg.get("deviceName") or "")
    shape = detect_shape(device_name, width, height)
    if face == "picture":
        return _lcd_skip("still")
    primary, secondary = _face_text(face, msg.get("cpu"), msg.get("gpu"), msg.get("coolant"))
    if face not in _STILL_FACES:
        if primary == "—":
            return _lcd_skip("no-temp")
        if face in ("cpu-gpu", "cpu-liquid") and secondary == "—":
            return _lcd_skip("no-temp")
    accent, second = _theme_colors()
    ink = _deepen_hex(accent, saturation) if accent else ""
    ink2 = _deepen_hex(second or accent, saturation) if (second or accent) else ""
    mark = _upload_mark(
        shape, width, height, face, ink, ink2, primary, secondary, brightness, angle,
    )
    # A still plate stays up until its mark changes. Temperature faces still
    # refresh on the interval so a quiet sensor does not look frozen.
    if face in _STILL_FACES and lcd_current_mark() == mark:
        return _lcd_skip("fresh")
    if not lcd_claim(mark, _lcd_seconds(msg.get("interval"))):
        return _lcd_skip("fresh")
    result = push_lcd_image(
        device, channel, brightness, face, angle, ink, ink2, primary, secondary,
        shape, width, height, device_name,
    )
    if not result.get("ok"):
        lcd_release(mark)
    return result


def _preview_pixels(width: int, height: int) -> tuple[int, int]:
    """Largest plate the dial can show. The cooler still receives its own size."""
    long_side = 1280
    w = max(1, int(width or 320))
    h = max(1, int(height or 320))
    scale = long_side / max(w, h)
    return max(32, int(round(w * scale))), max(32, int(round(h * scale)))


def lcd_preview(msg: dict) -> dict:
    """Write an upright plate for the dial. This does not touch the cooler."""
    face = str(msg.get("face") or "omarchy")
    width = _lcd_dim(msg.get("width")) or 320
    height = _lcd_dim(msg.get("height")) or 320
    device_name = str(msg.get("deviceName") or "")
    if device_name:
        shape = detect_shape(device_name, width, height)
    else:
        shape = "square" if str(msg.get("shape") or "") == "square" else "round"
    theme_accent, _second, _background, _foreground = _theme_fields()
    accent = str(msg.get("accent") or "")
    lit = accent if re.fullmatch(r"#[0-9A-Fa-f]{6}", accent) else (theme_accent or "#b59790")
    preview_w, preview_h = _preview_pixels(width, height)
    path = Path.home() / ".cache" / "omaflow" / "lcd-preview.png"
    try:
        if face == "picture":
            rendered = render_picture_png(
                str(msg.get("picture") or "") or _picture_path_from_view(),
                preview_w,
                preview_h,
                shape,
                0,
                msg.get("scale"),
            )
            if not rendered:
                return {"ok": False, "status": 0, "error": "picture unreadable", "body": None}
            png = rendered[0]
        else:
            if face not in _LOGO_FACES:
                face = "omarchy"
            png = lcd_logo.render_logo_png(
                face,
                lit or "#b59790",
                preview_w,
                preview_h,
                shape,
                0,
                clear=True,
            )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png)
        os.chmod(path, 0o600)
    except OSError as err:
        return {"ok": False, "status": 0, "error": str(err), "body": None}
    return {"ok": True, "status": 200, "error": "", "body": {"path": str(path)}}


def push_lcd_image(
    device: str,
    channel: str,
    brightness: int,
    face: str,
    angle: int,
    accent: str,
    accent2: str,
    temp_text: str,
    temp2: str,
    shape: str = "round",
    width: int = 0,
    height: int = 0,
    device_name: str = "",
    picture: str = "",
    scale: object = None,
) -> dict:
    token = read_token()
    if not token:
        return {"ok": False, "status": 0, "error": "need-token", "body": None}
    level = max(0, min(100, int(brightness)))
    painted = detect_shape(device_name, int(width or 0), int(height or 0)) if device_name else (
        "square" if str(shape or "round") == "square" else "round"
    )
    # The frame already carries the dial angle. A second daemon orientation would turn it again.
    picture_id = ""
    used_scale = None
    if str(face or "") == "picture":
        used_scale = _picture_scale(
            scale if scale is not None else (_lcd_view() or {}).get("pictureScale")
        )
        rendered = render_picture_png(
            picture or _picture_path_from_view(),
            int(width or 0) or 320,
            int(height or 0) or 320,
            painted,
            int(angle or 0),
            used_scale,
        )
        if not rendered:
            return {"ok": False, "status": 0, "error": "picture unreadable", "body": None}
        png, picture_id = rendered
    else:
        png = render_lcd_png(
            face or "liquid",
            temp_text or "—",
            temp2 or "",
            accent or "#b59790",
            accent2 or "#87a9b0",
            int(angle or 0),
            320,
            painted,
            int(width or 0) or None,
            int(height or 0) or None,
        )
    body, content_type = _multipart(
        [("mode", "image"), ("brightness", str(level)), ("orientation", "0")],
        "lcd.png",
        png,
    )
    path = (
        "/devices/"
        + urllib.parse.quote(device, safe="")
        + "/settings/"
        + urllib.parse.quote(channel, safe="")
        + "/lcd/images"
    )
    req = urllib.request.Request(
        BASE + path,
        data=body,
        headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Content-Type": content_type,
        },
        method="PUT",
    )
    try:
        with _open(req, 30) as res:
            raw = res.read()
            parsed = None
            if raw:
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except json.JSONDecodeError:
                    parsed = {"raw": raw.decode("utf-8", "replace")[:400]}
            try:
                lcd_remember(
                    _upload_mark(
                        painted,
                        int(width or 0),
                        int(height or 0),
                        str(face or "liquid"),
                        str(accent or ""),
                        str(accent2 or ""),
                        str(temp_text or "—"),
                        str(temp2 or ""),
                        level,
                        int(angle or 0) % 360,
                        picture_id,
                        used_scale,
                    )
                )
            except OSError:
                pass
            return {"ok": True, "status": res.status, "error": "", "body": parsed}
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:400]
        return {"ok": False, "status": err.code, "error": detail or str(err.reason), "body": None}
    except urllib.error.URLError as err:
        return {"ok": False, "status": 0, "error": str(err.reason), "body": None}
    except Exception as err:  # noqa: BLE001
        return {"ok": False, "status": 0, "error": str(err), "body": None}


def _safe_path(path: str) -> str | None:
    """A single daemon path. Refuses scheme, host, query, and fragment tricks."""
    text = str(path or "")
    if len(text) > 512 or not text.startswith("/") or text.startswith("//"):
        return None
    if any(ch in text for ch in ("?", "#", "\\", "\n", "\r", "\t", " ", "@", "\x00")):
        return None
    folded = text.lower()
    if "://" in text or ".." in text.split("/"):
        return None
    if "%2e" in folded or "%2f" in folded or "%5c" in folded:
        return None
    return text


def _own(path: Path) -> None:
    """Local preference files stay private to this user."""
    try:
        if path.is_file():
            os.chmod(path, 0o600)
    except OSError:
        pass


def _mode_activate(path: str) -> bool:
    if not path.startswith("/modes-active/"):
        return False
    uid = path[len("/modes-active/") :]
    return bool(uid) and "/" not in uid


def _theme_fields() -> tuple[str, str, str, str]:
    """Accent, second ink, background, and foreground from the active theme."""
    palette: dict[str, str] = {}
    try:
        raw = THEME_COLORS.read_text(encoding="utf-8")
    except OSError:
        raw = ""
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        value = value.strip()
        if " #" in value:
            value = value.split(" #", 1)[0].strip()
        value = value.strip().strip('"').strip("'")
        if re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
            palette[key.strip()] = value
    accent = palette.get("accent") or palette.get("color4") or ""
    second = palette.get("green") or palette.get("cyan") or palette.get("magenta") or accent
    background = palette.get("background") or palette.get("color0") or "#0a0c0b"
    foreground = palette.get("foreground") or palette.get("color7") or "#fafcfb"
    return accent, second, background, foreground


def _theme_colors() -> tuple[str, str]:
    accent, second, _background, _foreground = _theme_fields()
    return accent, second


def _rgb_to_hsl(red: int, green: int, blue: int) -> tuple[float, float, float]:
    rf, gf, bf = red / 255, green / 255, blue / 255
    high, low = max(rf, gf, bf), min(rf, gf, bf)
    light = (high + low) / 2
    if high == low:
        return 0.0, 0.0, light
    delta = high - low
    sat = delta / (1 - abs(2 * light - 1))
    if high == rf:
        hue = ((gf - bf) / delta) % 6
    elif high == gf:
        hue = (bf - rf) / delta + 2
    else:
        hue = (rf - gf) / delta + 4
    return hue / 6, sat, light


def _hsl_to_rgb(hue: float, sat: float, light: float) -> tuple[int, int, int]:
    def channel(n: int) -> float:
        k = (n + hue * 12) % 12
        a = sat * min(light, 1 - light)
        return light - a * max(-1, min(k - 3, 9 - k, 1))

    return tuple(max(0, min(255, int(round(channel(n) * 255)))) for n in (0, 8, 4))


def _deepen_hex(value: str, amount: int) -> str:
    """Same deepen as the LCD page: more saturation, a little less lightness."""
    red, green, blue = _parse_hex(value)
    hue, sat, light = _rgb_to_hsl(red, green, blue)
    t = max(0, min(100, int(amount))) / 100
    sat = min(1.0, sat + (1 - sat) * t * 0.55)
    light = max(0.2, light * (1 - 0.18 * t))
    out = _hsl_to_rgb(hue, sat, light)
    return "#%02x%02x%02x" % out


def _history_temps(row: dict) -> list:
    hist = row.get("status_history") or []
    if not hist or not isinstance(hist[-1], dict):
        return []
    temps = hist[-1].get("temps") or []
    return temps if isinstance(temps, list) else []


def _labeled_temps(device: dict, samples: list) -> list[tuple[str, float]]:
    info = ((device.get("info") or {}).get("temps") or {}) if isinstance(device, dict) else {}
    out: list[tuple[str, float]] = []
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        try:
            temp = float(sample.get("temp"))
        except (TypeError, ValueError):
            continue
        name = str(sample.get("name") or "")
        meta = info.get(name) if isinstance(info, dict) else None
        label = str(meta.get("label") or "") if isinstance(meta, dict) else ""
        out.append((label or name, temp))
    return out


def _match_temp(rows: list[tuple[str, float]], pattern: str):
    rx = re.compile(pattern, re.I)
    for name, temp in rows:
        if rx.search(name):
            return temp
    return None


def _pick_temp(rows: list[tuple[str, float]], pattern: str):
    found = _match_temp(rows, pattern)
    if found is not None:
        return found
    if not rows:
        return None
    return max(temp for _, temp in rows)


def _gpu_edge(rows: list[tuple[str, float]]):
    """Edge temperature. Hotspot loses to any other GPU sensor."""
    best = None
    rank = -1
    for name, temp in rows:
        score = 1
        if re.search(r"hotspot|hot spot", name, re.I):
            score = 0
        if re.search(r"edge", name, re.I):
            score = 3
        if re.search(r"gpu temp$", name, re.I):
            score = 4
        if score > rank:
            rank = score
            best = temp
    return best


def _whole(value) -> str:
    if value is None:
        return "—"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "—"
    if number != number:
        return "—"
    return str(int(round(number)))


def _screen_numbers(face: str, devices: list, status: dict) -> tuple[str, str]:
    if face in _STILL_FACES:
        return "", ""
    info_by = {d.get("uid"): d for d in devices if isinstance(d, dict)}
    cpu = None
    gpu = None
    coolant = None
    for row in status.get("devices") or []:
        if not isinstance(row, dict):
            continue
        device = info_by.get(row.get("uid")) or {}
        labeled = _labeled_temps(device, _history_temps(row))
        kind = str(device.get("type") or row.get("type") or "")
        if kind == "CPU":
            cpu = _pick_temp(labeled, r"package|tctl|tdie")
        elif kind == "GPU":
            gpu = _gpu_edge(labeled)
        for name, temp in labeled:
            if re.search(r"liquid|coolant|water", name, re.I):
                coolant = temp
    if face in ("cpu", "cpu-gpu", "cpu-liquid"):
        primary = _whole(cpu)
    else:
        primary = _whole(coolant)
    secondary = ""
    if face == "cpu-gpu":
        secondary = _whole(gpu)
    elif face == "cpu-liquid":
        secondary = _whole(coolant)
    return primary, secondary


def _lcd_target(devices: list):
    for dev in devices:
        if not isinstance(dev, dict):
            continue
        channels = (dev.get("info") or {}).get("channels") or {}
        if not isinstance(channels, dict):
            continue
        for name, info in channels.items():
            if not isinstance(info, dict) or not info.get("lcd_modes"):
                continue
            lcd = info.get("lcd_info") or {}
            try:
                width = int(lcd.get("screen_width") or 0)
                height = int(lcd.get("screen_height") or 0)
            except (TypeError, ValueError):
                width, height = 0, 0
            return str(dev.get("uid") or ""), str(name), width, height, str(dev.get("name") or "")
    return None


def restore_saved_lcd() -> None:
    """Put the saved pump image back at daemon orientation 0.

    A mode stores its own LCD orientation. Applying it turns an image that
    already carries the dial angle. The Kraken driver bakes the register it
    reads into the pixels, so the upload that writes 0 is followed by a
    second upload. The image upload keeps the active mode; a plain LCD
    settings write would clear it.
    """
    def give_up(reason: str) -> None:
        sys.stderr.write("omaflow lcd restore: %s\n" % reason)
        sys.stderr.flush()

    _own(LCD_VIEW_PATH)
    view = _lcd_view()
    if view is None:
        give_up("saved lcd view is unreadable")
        return
    devices = call("GET", "/devices", None)
    if not devices.get("ok"):
        give_up(devices.get("error") or "device list rejected")
        return
    body = devices.get("body")
    devs = body if isinstance(body, list) else (body or {}).get("devices") or []
    if not isinstance(devs, list):
        give_up("device list rejected")
        return
    target = _lcd_target(devs)
    if not target or not target[0]:
        give_up("no lcd channel")
        return
    uid, channel, width, height, device_name = target
    status = call("GET", "/status", None)
    status_body = status.get("body") if status.get("ok") and isinstance(status.get("body"), dict) else {"devices": []}
    face = str(view.get("face") or "liquid")
    primary, secondary = _screen_numbers(face, devs, status_body)
    brightness = _bound_int(view.get("brightness"), 80)
    saturation = _bound_int(view.get("saturation"), 0)
    try:
        angle = int(view.get("angle") or 0)
    except (TypeError, ValueError):
        angle = 0
    shape = detect_shape(device_name, width, height)
    accent, second = _theme_colors()
    ink = _deepen_hex(accent, saturation) if accent else ""
    ink2 = _deepen_hex(second or accent, saturation) if (second or accent) else ""

    def push_once() -> dict:
        return push_lcd_image(
            uid, channel, brightness, face, angle, ink, ink2, primary, secondary,
            shape, width, height, device_name,
        )

    # liquidctl reads the Kraken orientation register and bakes that turn into
    # the pixels. The upload that writes orientation 0 can still bake the
    # mode's previous angle. The next upload reads the register after that write.
    result = push_once()
    if not result.get("ok"):
        time.sleep(0.4)
        result = push_once()
    if result.get("ok"):
        time.sleep(0.35)
        result = push_once()
    if not result.get("ok"):
        time.sleep(0.4)
        result = push_once()
    if not result.get("ok"):
        sys.stderr.write("omaflow lcd restore: %s\n" % (result.get("error") or "image rejected"))
        sys.stderr.flush()


def _speed_signature(setting: dict) -> tuple[str, str, str] | None:
    """Fan or pump assignment. LCD and lighting uploads are not a mode."""
    if not isinstance(setting, dict):
        return None
    if setting.get("lcd") or setting.get("lighting"):
        return None
    channel = str(setting.get("channel_name") or "")
    if not channel:
        return None
    profile = setting.get("profile_uid")
    fixed = setting.get("speed_fixed")
    if not profile and fixed is None:
        return None
    return (channel, str(profile or ""), "" if fixed is None else str(fixed))


def _mode_setting_rows(mode: dict) -> list:
    """device_settings is a list of pairs, or a map of device uid to rows."""
    raw = mode.get("device_settings") if isinstance(mode, dict) else None
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        return [[key, value] for key, value in raw.items()]
    return []


def _infer_active_mode() -> str:
    """Mode whose fan and pump assignments match the live device settings.

    coolercontrold 5.1 clears current_mode_uid when the pump image is
    uploaded. The curves stay. Match those, ignoring LCD rows.
    """
    modes_res = _request("GET", "/modes", None)
    devices_res = _request("GET", "/devices", None)
    if not modes_res.get("ok") or not devices_res.get("ok"):
        return ""
    modes_body = modes_res.get("body") if isinstance(modes_res.get("body"), dict) else {}
    devices_body = devices_res.get("body") if isinstance(devices_res.get("body"), dict) else {}
    modes = modes_body.get("modes") if isinstance(modes_body.get("modes"), list) else []
    devices = devices_body.get("devices") if isinstance(devices_body.get("devices"), list) else []
    live: dict[tuple[str, str], tuple[str, str, str]] = {}
    for dev in devices:
        if not isinstance(dev, dict):
            continue
        uid = str(dev.get("uid") or "")
        if not uid:
            continue
        settings_res = _request("GET", "/devices/" + urllib.parse.quote(uid, safe="") + "/settings", None)
        settings_body = settings_res.get("body") if settings_res.get("ok") and isinstance(settings_res.get("body"), dict) else {}
        for setting in settings_body.get("settings") or []:
            sig = _speed_signature(setting if isinstance(setting, dict) else {})
            if sig:
                live[(uid, sig[0])] = sig
    if not live:
        return ""
    winners: list[tuple[int, str]] = []
    for mode in modes:
        if not isinstance(mode, dict):
            continue
        compared = 0
        mismatch = False
        for pair in _mode_setting_rows(mode):
            if not isinstance(pair, (list, tuple)) or len(pair) < 2:
                continue
            dev = str(pair[0] or "")
            rows = pair[1] if isinstance(pair[1], list) else []
            for setting in rows:
                sig = _speed_signature(setting if isinstance(setting, dict) else {})
                if not sig:
                    continue
                current = live.get((dev, sig[0]))
                if current is None:
                    continue
                compared += 1
                if current != sig:
                    mismatch = True
        if compared and not mismatch:
            winners.append((compared, str(mode.get("uid") or "")))
    if not winners:
        return ""
    winners.sort(key=lambda item: item[0], reverse=True)
    if len(winners) > 1 and winners[0][0] == winners[1][0]:
        return ""
    return winners[0][1]


def _request(method: str, path: str, body) -> dict:
    token = read_token()
    if not token:
        return {"ok": False, "status": 0, "error": "need-token", "body": None}
    if not path.startswith("/"):
        path = "/" + path
    data = None
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        with _open(req, 8) as res:
            raw = res.read()
            parsed = None
            if raw:
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except json.JSONDecodeError:
                    parsed = {"raw": raw.decode("utf-8", "replace")[:400]}
            return {"ok": True, "status": res.status, "error": "", "body": parsed}
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:400]
        return {"ok": False, "status": err.code, "error": detail or err.reason, "body": None}
    except urllib.error.URLError as err:
        return {"ok": False, "status": 0, "error": str(err.reason), "body": None}
    except Exception as err:  # noqa: BLE001 — one bad call must not kill the client
        return {"ok": False, "status": 0, "error": str(err), "body": None}


def _fill_active_mode(result: dict) -> dict:
    """An empty active mode follows a pump-image upload. Infer it once."""
    if not result.get("ok"):
        return result
    payload = result.get("body")
    if not isinstance(payload, dict) or payload.get("current_mode_uid"):
        return result
    inferred = _infer_active_mode()
    if not inferred:
        return result
    filled = dict(payload)
    filled["current_mode_uid"] = inferred
    result["body"] = filled
    return result


def call(method: str, path: str, body) -> dict:
    result = _request(method, path, body)
    if method != "GET" or path.rstrip("/") != "/modes-active":
        return result
    return _fill_active_mode(result)


_CATALOG = (
    ("devices", "/devices"),
    ("profiles", "/profiles"),
    ("modes", "/modes"),
    ("modesActive", "/modes-active"),
    ("settings", "/settings"),
    ("functions", "/functions"),
    ("alerts", "/alerts"),
    ("status", "/status"),
    ("calibrations", "/calibrations"),
    ("calibrationBatch", "/calibrations/batch"),
)


def _exchange(conn: http.client.HTTPConnection, path: str, token: str) -> dict:
    """One request on an already identified connection. Redirects are not followed."""
    conn.request(
        "GET",
        path,
        headers={
            "Host": "%s:%s" % (_DAEMON_HOST, _DAEMON_PORT),
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
            "Connection": "keep-alive",
        },
    )
    res = conn.getresponse()
    raw = res.read()
    if res.status in (301, 302, 303, 307, 308):
        return {"ok": False, "status": res.status, "error": "redirect refused", "body": None}
    parsed = None
    if raw:
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            parsed = {"raw": raw.decode("utf-8", "replace")[:400]}
    if 200 <= res.status < 300:
        return {"ok": True, "status": res.status, "error": "", "body": parsed}
    detail = ""
    if isinstance(parsed, str):
        detail = parsed[:400]
    elif raw:
        detail = raw.decode("utf-8", "replace")[:400]
    return {"ok": False, "status": res.status, "error": detail or str(res.status), "body": None}


def catalog() -> dict:
    """The window's startup reads, on one connection so the listener is checked once."""
    token = read_token()
    if not token:
        return {"ok": False, "status": 0, "error": "need-token", "body": None}
    conn = _DaemonConnection(_DAEMON_HOST, _DAEMON_PORT, timeout=8)
    body: dict = {}
    try:
        conn.connect()
        for key, path in _CATALOG:
            try:
                result = _exchange(conn, path, token)
            except Exception as err:  # noqa: BLE001 — one dropped socket ends the burst
                body[key] = {"ok": False, "status": 0, "error": str(err), "body": None}
                break
            if path == "/modes-active":
                result = _fill_active_mode(result)
            body[key] = result
            status = int(result.get("status") or 0)
            if status in (301, 302, 303, 307, 308, 401, 403):
                break
        return {"ok": True, "status": 200, "error": "", "body": body}
    except OSError as err:
        return {"ok": False, "status": 0, "error": str(err), "body": None}
    finally:
        conn.close()


def _parse_sse(block: str) -> None:
    event = "message"
    data = []
    for line in block.split("\n"):
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].lstrip())
    if not data:
        return
    raw = "\n".join(data)
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        body = {"raw": raw[:400]}
    emit({"event": event, "body": body})


def watch() -> None:
    announced = False
    while not _STOP.is_set():
        token = read_token()
        if not token:
            if not announced:
                emit({"event": "down", "error": "need-token"})
                announced = True
            _STOP.wait(2)
            continue
        announced = False
        req = urllib.request.Request(
            BASE + "/sse?events=status,modes,alerts",
            headers={"Authorization": "Bearer " + token, "Accept": "text/event-stream"},
            method="GET",
        )
        try:
            with _open(req, None) as res:
                emit({"event": "up"})
                buf = ""
                while not _STOP.is_set():
                    chunk = res.read(4096)
                    if not chunk:
                        break
                    buf += chunk.decode("utf-8", "replace")
                    if len(buf) > _SSE_LIMIT:
                        break
                    while "\n\n" in buf:
                        block, buf = buf.split("\n\n", 1)
                        _parse_sse(block.replace("\r\n", "\n").replace("\r", "\n"))
        except urllib.error.HTTPError as err:
            emit({"event": "down", "error": "http %s" % err.code, "status": err.code})
        except urllib.error.URLError as err:
            emit({"event": "down", "error": str(err.reason)})
        except Exception as err:  # noqa: BLE001
            emit({"event": "down", "error": str(err)})
        _STOP.wait(2)


def lcd_face_check() -> None:
    """Every temperature face on the four liquidctl buffers, plus shape detection."""
    from PIL import Image

    devices = (
        ("NZXT Kraken Z (Z53, Z63 or Z73)", 320, 320, "round"),
        ("NZXT Kraken 2024 Elite RGB", 640, 640, "round"),
        ("NZXT Kraken 2023", 240, 240, "square"),
        ("NZXT Kraken 2024 Plus", 240, 240, "square"),
        ("MSI MPG CoreLiquid K360", 240, 320, "square"),
        ("ASUS Ryujin II 360", 240, 240, "square"),
    )
    for name, width, height, shape in devices:
        got = detect_shape(name, width, height)
        if got != shape:
            raise SystemExit("%s detected %s" % (name, got))
    buffers = ((320, 320, "round"), (640, 640, "round"), (240, 240, "square"), (240, 320, "square"))
    faces = ("liquid", "cpu", "cpu-gpu", "cpu-liquid")
    out = Path("/tmp/omaflow-lcd-check")
    out.mkdir(parents=True, exist_ok=True)
    for width, height, shape in buffers:
        for face in faces:
            secondary = "61" if face in ("cpu-gpu", "cpu-liquid") else ""
            raw = render_lcd_png(face, "54", secondary, "#7fbbb3", "#a7c080", 0, 320, shape, width, height)
            image = Image.open(io.BytesIO(raw))
            if image.size != (width, height) or image.mode != "RGB":
                raise SystemExit("%s %s is %s" % (face, shape, image.size))
            pixels = image.load()
            for x, y in ((0, 0), (width - 1, 0), (0, height - 1), (1, height // 2), (width // 2, 1)):
                if pixels[x, y] != _LCD_BG:
                    raise SystemExit("%s %sx%s edge %s,%s %s" % (face, width, height, x, y, pixels[x, y]))
            image.save(out / ("temp-%s-%sx%s.png" % (face, width, height)))
            image.close()
    preview = _preview_pixels(320, 320)
    if preview != (1280, 1280):
        raise SystemExit("round preview is %s" % (preview,))
    tall = _preview_pixels(240, 320)
    if tall != (960, 1280):
        raise SystemExit("portrait preview is %s" % (tall,))
    quiet = _upload_mark("round", 320, 320, "omarchy", "#7fbbb3", "", "10", "20", 50, 0)
    hot = _upload_mark("round", 320, 320, "omarchy", "#7fbbb3", "", "99", "88", 50, 0)
    if quiet != hot:
        raise SystemExit("omarchy mark followed the temperature")
    clock = _upload_mark("round", 320, 320, "omarchy-time", "#7fbbb3", "", "10", "20", 50, 0)
    if clock == quiet or time.strftime("%H:%M") not in clock:
        raise SystemExit("clock mark missed the minute")
    print("lcd faces ok")


def processes_snapshot() -> dict:
    """Shared CPU and GPU sample for the window and the bar.

    Temperatures, fans, and the pump stay on coolercontrold's one poll.
    Process lists are not in that daemon, so both clients share one snapshot
    and one nvidia-smi.
    """
    import process_snap
    return process_snap.snapshot()


def main() -> None:
    _own(LCD_VIEW_PATH)
    if not read_token():
        pair(FACTORY_PASSWORD)
    token = read_token()
    emit({"event": "hello", "token": bool(token)})
    threading.Thread(target=watch, name="cc-sse", daemon=True).start()
    for line in sys.stdin:
        if _STOP.is_set():
            break
        text = line.strip()
        if not text:
            continue
        try:
            msg = json.loads(text)
        except json.JSONDecodeError:
            emit({"event": "error", "error": "bad request"})
            continue
        op = msg.get("op")
        if op == "quit":
            _STOP.set()
            break
        if op == "reload":
            emit({"event": "hello", "token": bool(read_token())})
            continue
        if op == "groups-get":
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_groups()})
            continue
        if op == "groups-set":
            body = msg.get("body") if isinstance(msg.get("body"), dict) else {}
            write_groups(body)
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": None})
            continue
        if op == "links-get":
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_links()})
            continue
        if op == "links-set":
            body = msg.get("body") if isinstance(msg.get("body"), dict) else {}
            write_links(body)
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": None})
            continue
        if op == "hidden-get":
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_hidden()})
            continue
        if op == "hidden-set":
            body = msg.get("body") if isinstance(msg.get("body"), dict) else {}
            write_hidden(body)
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": None})
            continue
        if op == "processes":
            try:
                body = processes_snapshot()
            except Exception:
                emit({"id": msg.get("id"), "ok": False, "status": 0, "error": "processes failed", "body": None})
                continue
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": body})
            continue
        if op == "ui-get":
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_ui()})
            continue
        if op == "ui-set":
            body = msg.get("body") if isinstance(msg.get("body"), dict) else {}
            write_ui(body)
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_ui()})
            continue
        if op == "pack-get":
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_pack()})
            continue
        if op == "pack-set":
            body = msg.get("body") if isinstance(msg.get("body"), dict) else {}
            try:
                write_pack(body)
            except ValueError as err:
                emit({"id": msg.get("id"), "ok": False, "status": 400, "error": str(err), "body": None})
                continue
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": read_pack()})
            continue
        if op == "pack-clear":
            clear_pack()
            emit({"id": msg.get("id"), "ok": True, "status": 200, "error": "", "body": {}})
            continue
        if op == "file-read":
            result = read_user_json(str(msg.get("path") or ""))
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op == "file-write":
            body = msg.get("body") if isinstance(msg.get("body"), dict) else {}
            result = write_user_json(str(msg.get("path") or ""), body)
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op == "pair":
            result = pair(str(msg.get("password") or ""))
            result["id"] = msg.get("id")
            emit(result)
            if result.get("ok"):
                emit({"event": "hello", "token": True})
            continue
        if op == "lcd-keep":
            result = lcd_keep(msg if isinstance(msg, dict) else {})
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op == "lcd-preview":
            result = lcd_preview(msg if isinstance(msg, dict) else {})
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op == "lcd-image":
            result = push_lcd_image(
                str(msg.get("device") or ""),
                str(msg.get("channel") or ""),
                int(msg.get("brightness") or 0),
                str(msg.get("face") or "liquid"),
                int(msg.get("angle") or 0),
                str(msg.get("accent") or ""),
                str(msg.get("accent2") or ""),
                str(msg.get("temp") or ""),
                str(msg.get("temp2") or ""),
                str(msg.get("shape") or "round"),
                int(msg.get("width") or 0),
                int(msg.get("height") or 0),
                str(msg.get("deviceName") or ""),
                str(msg.get("picture") or ""),
                msg.get("scale"),
            )
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op == "catalog":
            result = catalog()
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op != "call":
            continue
        method = str(msg.get("method") or "GET").upper()
        path = _safe_path(str(msg.get("path") or "/"))
        if method not in _METHODS or path is None:
            emit({"id": msg.get("id"), "ok": False, "status": 0, "error": "request refused", "body": None})
            continue
        result = call(method, path, msg.get("body"))
        if result.get("ok") and method == "POST" and _mode_activate(path):
            try:
                restore_saved_lcd()
            except Exception as err:  # noqa: BLE001 — the mode itself already applied
                sys.stderr.write("omaflow lcd restore: %s\n" % err)
        result["id"] = msg.get("id")
        emit(result)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        _STOP.set()
