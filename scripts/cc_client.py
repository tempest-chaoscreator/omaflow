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
_LCD_STOPS = {2, 5, 10, 30, 60}
_LCD_FACES = ("liquid", "cpu", "cpu-gpu", "cpu-liquid", "omarchy", "omarchy-time")
_LOGO_FACES = ("omarchy", "omarchy-time")
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


def _store_token(token: str) -> None:
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (token + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(TOKEN_PATH, 0o600)


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


def _open(req: urllib.request.Request, timeout: float | None, jar: CookieJar | None = None):
    return _daemon_opener(jar).open(req, timeout=timeout)


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


def read_groups() -> dict:
    try:
        data = json.loads(GROUPS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"groups": []}
    if not isinstance(data, dict) or not isinstance(data.get("groups"), list):
        return {"groups": []}
    return data


def write_groups(data: dict) -> None:
    GROUPS_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"groups": data.get("groups") or []}, indent=2).encode("utf-8")
    fd = os.open(GROUPS_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)
    os.chmod(GROUPS_PATH, 0o600)


def read_links() -> dict:
    """Per-card curve link flags. Missing keys use the app defaults."""
    try:
        data = json.loads(LINKS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"links": {}}
    raw = data.get("links") if isinstance(data, dict) else None
    if not isinstance(raw, dict):
        return {"links": {}}
    clean = {}
    for key, value in raw.items():
        if not isinstance(key, str) or len(key) > 80:
            continue
        if isinstance(value, bool):
            clean[key] = value
        if len(clean) >= 200:
            break
    return {"links": clean}


def _clean_hidden(raw: object) -> dict:
    """Device uids the user hid. Absent means shown."""
    if not isinstance(raw, dict):
        return {}
    clean = {}
    for key, value in raw.items():
        if not isinstance(key, str) or not key or len(key) > 80:
            continue
        if value is True:
            clean[key] = True
        if len(clean) >= 200:
            break
    return clean


def read_hidden() -> dict:
    try:
        data = json.loads(HIDDEN_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"devices": {}}
    raw = data.get("devices") if isinstance(data, dict) else None
    return {"devices": _clean_hidden(raw)}


def write_hidden(data: dict) -> None:
    raw = data.get("devices") if isinstance(data, dict) else None
    clean = _clean_hidden(raw)
    HIDDEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"devices": clean}, indent=2).encode("utf-8")
    fd = os.open(HIDDEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)
    os.chmod(HIDDEN_PATH, 0o600)


def _lcd_seconds(value: object) -> int:
    try:
        seconds = int(str(value))
    except (TypeError, ValueError):
        return 5
    return seconds if seconds in _LCD_STOPS else 5


def read_ui() -> dict:
    default = {
        "dynamicScale": False,
        "pinGroups": False,
        "textFollow": True,
        "textSize": 12,
        "showBar": True,
        # Absent means the plugin keeps drawing the pump. Only an explicit false stops it.
        "lcdBackground": True,
        "lcdSeconds": 5,
        "lcdThemeSync": False,
    }
    try:
        raw = json.loads(UI_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default
    if not isinstance(raw, dict):
        return default
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
    }


def write_ui(data: dict) -> None:
    clean = read_ui()
    if isinstance(data, dict):
        if "dynamicScale" in data:
            clean["dynamicScale"] = data.get("dynamicScale") is True
        if "pinGroups" in data:
            clean["pinGroups"] = data.get("pinGroups") is True
        if "textFollow" in data:
            clean["textFollow"] = data.get("textFollow") is not False
        if "textSize" in data:
            try:
                size = int(data.get("textSize"))
            except (TypeError, ValueError):
                size = clean["textSize"]
            if size in _TEXT_STOPS:
                clean["textSize"] = size
        if "showBar" in data:
            clean["showBar"] = data.get("showBar") is not False
        if "lcdBackground" in data:
            clean["lcdBackground"] = data.get("lcdBackground") is not False
        if "lcdSeconds" in data:
            clean["lcdSeconds"] = _lcd_seconds(data.get("lcdSeconds"))
        if "lcdThemeSync" in data:
            clean["lcdThemeSync"] = data.get("lcdThemeSync") is True
    _write_private(UI_PATH, json.dumps(clean, indent=2).encode("utf-8"))


def read_pack() -> dict:
    try:
        raw = json.loads(PACK_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(raw, dict) or raw.get("kind") != "omaflow-curves":
        return {}
    return raw


def write_pack(data: dict) -> None:
    if not isinstance(data, dict) or data.get("kind") != "omaflow-curves":
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


def _write_private(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def write_links(data: dict) -> None:
    raw = data.get("links") if isinstance(data, dict) else None
    if not isinstance(raw, dict):
        raw = {}
    clean = {}
    for key, value in raw.items():
        if not isinstance(key, str) or len(key) > 80:
            continue
        if isinstance(value, bool):
            clean[key] = value
        if len(clean) >= 200:
            break
    LINKS_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"links": clean}, indent=2).encode("utf-8")
    fd = os.open(LINKS_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, payload)
    finally:
        os.close(fd)
    os.chmod(LINKS_PATH, 0o600)


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


def _draw_center(draw, size: int, text: str, y: float, font, fill) -> None:
    box = draw.textbbox((0, 0), text, font=font)
    width = box[2] - box[0]
    draw.text(
        ((size - width) / 2 - box[0], y - box[1]),
        text,
        font=font,
        fill=fill,
        stroke_width=2,
        stroke_fill=(0, 0, 0),
    )


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


def _render_round(face: str, primary: str, secondary: str, accent: str, accent2: str, angle: int, size: int) -> bytes:
    """Upright frame, then turned clockwise by `angle`. The daemon orientation stays 0.

    Stroke and type scale from the 320 design so a 240 circle and a 640 circle match it.
    """
    from PIL import Image, ImageDraw
    image = Image.new("RGB", (size, size), _LCD_BG)
    draw = ImageDraw.Draw(image)
    ink = _parse_hex(accent)
    ink2 = _parse_hex(accent2 or accent)
    scale = size / 320
    margin = max(8, int(round(22 * scale)))
    stroke = max(4, int(round(14 * scale)))
    box = [margin, margin, size - margin - 1, size - margin - 1]
    combo = face in ("cpu-gpu", "cpu-liquid")
    if combo:
        # Pillow measures arcs clockwise from 3 o'clock. Left half, then right half.
        draw.arc(box, start=90, end=270, fill=ink, width=stroke)
        draw.arc(box, start=270, end=90, fill=ink2, width=stroke)
    else:
        draw.ellipse(box, outline=ink, width=stroke)
    left, right = _face_labels(face)
    number = primary if primary else "—"
    if combo:
        other = secondary if secondary else "—"
        number_font = _lcd_font(max(12, int(round(78 * scale))))
        label_font = _lcd_font(max(10, int(round(22 * scale))))
        _draw_at(draw, size * 0.34, size * 0.40, number, number_font, ink)
        _draw_at(draw, size * 0.66, size * 0.40, other, number_font, ink2)
        _draw_at(draw, size * 0.34, size * 0.62, left, label_font, ink)
        _draw_at(draw, size * 0.66, size * 0.62, right, label_font, ink2)
        draw.line(
            [(size / 2, size * 0.34), (size / 2, size * 0.70)],
            fill=(250, 252, 251),
            width=max(1, int(round(2 * scale))),
        )
    else:
        number_font = _lcd_font(max(16, int(round(104 * scale))))
        label_font = _lcd_font(max(10, int(round(26 * scale))))
        _draw_center(draw, size, number, size * 0.36, number_font, ink)
        _draw_center(draw, size, left, size * 0.62, label_font, ink)
    turned = int(angle) % 360
    if turned:
        image = image.rotate(-turned, resample=Image.Resampling.BICUBIC, expand=False, fillcolor=_LCD_BG)
    buf = io.BytesIO()
    image.save(buf, "PNG")
    image.close()
    return buf.getvalue()


def _render_square(face: str, primary: str, secondary: str, accent: str, accent2: str, angle: int, width: int, height: int) -> bytes:
    """Square-panel frame. Rotation stays inside the reported pixel buffer."""
    from PIL import Image, ImageDraw
    image = Image.new("RGB", (width, height), _LCD_BG)
    draw = ImageDraw.Draw(image)
    ink = _parse_hex(accent)
    ink2 = _parse_hex(accent2 or accent)
    scale = min(width, height) / 320
    margin = max(8, int(round(22 * scale)))
    stroke = max(4, int(round(14 * scale)))
    right_edge = width - margin - 1
    bottom = height - margin - 1
    combo = face in ("cpu-gpu", "cpu-liquid")
    draw.rectangle([margin, margin, right_edge, bottom], outline=ink, width=stroke)
    if combo:
        mid = width / 2
        draw.line([(mid, margin), (right_edge, margin)], fill=ink2, width=stroke)
        draw.line([(right_edge, margin), (right_edge, bottom)], fill=ink2, width=stroke)
        draw.line([(mid, bottom), (right_edge, bottom)], fill=ink2, width=stroke)
    left, right = _face_labels(face)
    number = primary if primary else "—"
    if combo:
        other = secondary if secondary else "—"
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
    else:
        number_font = _lcd_font(max(16, int(round(104 * scale))))
        label_font = _lcd_font(max(10, int(round(26 * scale))))
        _draw_center(draw, width, number, height * 0.36, number_font, ink)
        _draw_center(draw, width, left, height * 0.62, label_font, ink)
    turned = int(angle) % 360
    if turned:
        image = image.rotate(-turned, resample=Image.Resampling.BICUBIC, expand=False, fillcolor=_LCD_BG)
    buf = io.BytesIO()
    image.save(buf, "PNG")
    image.close()
    return buf.getvalue()


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
        buf = io.BytesIO()
        base.save(buf, "PNG")
        base.close()
        return buf.getvalue()
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
) -> str:
    """The lease key. Logo faces ignore temperatures. The clock changes once a minute."""
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
    """Exclusive access to the one-writer stamp shared by the window and the plugin."""
    LCD_LEASE_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(LCD_LEASE_PATH, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.chmod(LCD_LEASE_PATH, 0o600)
        blob = b""
        while len(blob) <= 16384:
            chunk = os.read(fd, 4096)
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
            os.write(fd, raw)
        return prev
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
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
        if str(prev.get("mark") or "") == mark and now - prev_at < window:
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
    if face in _LOGO_FACES:
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
    try:
        view = json.loads(LCD_VIEW_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return _lcd_skip("no-view")
    if not isinstance(view, dict):
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
    if face not in _LCD_FACES:
        face = "liquid"
    try:
        brightness = int(view.get("brightness"))
    except (TypeError, ValueError):
        brightness = 80
    brightness = max(0, min(100, brightness))
    try:
        saturation = int(view.get("saturation"))
    except (TypeError, ValueError):
        saturation = 0
    saturation = max(0, min(100, saturation))
    try:
        angle = int(view.get("angle") or 0)
    except (TypeError, ValueError):
        angle = 0
    angle = angle % 360
    width = _lcd_dim(msg.get("width"))
    height = _lcd_dim(msg.get("height"))
    device_name = str(msg.get("deviceName") or "")
    shape = detect_shape(device_name, width, height)
    primary, secondary = _face_text(face, msg.get("cpu"), msg.get("gpu"), msg.get("coolant"))
    if face not in _LOGO_FACES:
        if primary == "—":
            return _lcd_skip("no-temp")
        if face in ("cpu-gpu", "cpu-liquid") and secondary == "—":
            return _lcd_skip("no-temp")
    accent, second = _theme_colors()
    ink = _deepen_hex(accent, saturation) if accent else ""
    ink2 = _deepen_hex(second or accent, saturation) if (second or accent) else ""
    mark = _upload_mark(shape, width, height, face, ink, ink2, primary, secondary, brightness, angle)
    # A logo plate stays up until its mark changes. Temperature faces still
    # refresh on the interval so a quiet sensor does not look frozen.
    if face in _LOGO_FACES and lcd_current_mark() == mark:
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
    """Write an upright transparent plate for the dial. This does not touch the cooler."""
    face = str(msg.get("face") or "omarchy")
    if face not in _LOGO_FACES:
        face = "omarchy"
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
) -> dict:
    token = read_token()
    if not token:
        return {"ok": False, "status": 0, "error": "need-token", "body": None}
    level = max(0, min(100, int(brightness)))
    painted = detect_shape(device_name, int(width or 0), int(height or 0)) if device_name else (
        "square" if str(shape or "round") == "square" else "round"
    )
    # The frame already carries the dial angle. A second daemon orientation would turn it again.
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
    if face in _LOGO_FACES:
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
            gpu = _match_temp(labeled, r"gpu temp$")
            if gpu is None:
                gpu = _pick_temp(labeled, r"edge|gpu|temp")
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
    try:
        view = json.loads(LCD_VIEW_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        give_up("saved lcd view is unreadable")
        return
    if not isinstance(view, dict):
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
    try:
        brightness = int(view.get("brightness"))
    except (TypeError, ValueError):
        brightness = 80
    try:
        saturation = int(view.get("saturation"))
    except (TypeError, ValueError):
        saturation = 0
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


def call(method: str, path: str, body) -> dict:
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
            BASE + "/sse?events=status,modes",
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


_NVIDIA_SMI = "/usr/bin/nvidia-smi"
_GPU_LOCK = threading.Lock()
_GPU = {"ok": True, "rows": [], "util": 0.0, "fail": 0, "empty": 0, "running": False}
_CPU_PREV: tuple | None = None
_PMON_ROW = re.compile(
    r"^\s*\d+\s+(\d+)\s+\S+\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(.*\S)\s*$"
)


def _user_comm(pid: int) -> str | None:
    """Command name for a userspace process. Kernel threads have an empty cmdline."""
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return None
    if not raw.strip(b"\x00"):
        return None
    try:
        name = Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return name or None


def _stat_ticks(pid: int) -> int | None:
    try:
        text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except OSError:
        return None
    end = text.rfind(")")
    if end < 0:
        return None
    fields = text[end + 2 :].split()
    if len(fields) < 13:
        return None
    try:
        return int(fields[11]) + int(fields[12])
    except ValueError:
        return None


def _cpu_times() -> tuple[int, int] | None:
    """Aggregate cpu ticks and idle ticks (idle + iowait) from /proc/stat."""
    try:
        first = Path("/proc/stat").read_text(encoding="utf-8").splitlines()[0]
    except OSError:
        return None
    parts = first.split()
    if not parts or parts[0] != "cpu":
        return None
    nums: list[int] = []
    for part in parts[1:]:
        try:
            nums.append(int(part))
        except ValueError:
            return None
    if len(nums) < 5:
        return None
    return sum(nums), nums[3] + nums[4]


def _share_percent(delta_ticks: int, total_delta: int) -> float:
    """This process's share of the whole CPU, 0 to 100, not one core."""
    if delta_ticks <= 0 or total_delta <= 0:
        return 0.0
    return delta_ticks / total_delta * 100.0


def _cpu_sample() -> tuple[list[dict], float]:
    """Rows grouped by command, plus total CPU load from 0 to 100.

    percent stays the per-core sample the LED scale already uses.
    share is the label: that same time as a percent of every core.
    Idle commands stay in the list so a quiet sample still fills the table.
    """
    global _CPU_PREV
    times = _cpu_times()
    total = times[0] if times else None
    idle = times[1] if times else None
    now = time.monotonic()
    procs: dict[int, tuple[str, int]] = {}
    try:
        names = os.listdir("/proc")
    except OSError:
        names = []
    for name in names:
        if not name.isdigit():
            continue
        pid = int(name)
        comm = _user_comm(pid)
        if not comm or comm == "nvidia-smi":
            continue
        ticks = _stat_ticks(pid)
        if ticks is None:
            continue
        procs[pid] = (comm, ticks)
    prev = _CPU_PREV
    _CPU_PREV = (now, total, idle, procs)
    if prev is None or total is None or idle is None or prev[1] is None or prev[2] is None:
        return [], 0.0
    dt = now - prev[0]
    if dt <= 0.2:
        return [], 0.0
    try:
        hz = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    except (OSError, ValueError, KeyError):
        hz = 100
    if hz <= 0:
        hz = 100
    total_delta = total - int(prev[1])
    idle_delta = idle - int(prev[2])
    busy = 0.0
    if total_delta > 0:
        busy = (1.0 - (idle_delta / total_delta)) * 100.0
        if busy < 0:
            busy = 0.0
        if busy > 100:
            busy = 100.0
    grouped: dict[str, list] = {}
    old_procs = prev[3]
    for pid, (comm, ticks) in procs.items():
        old = old_procs.get(pid)
        delta = ticks - old[1] if old else 0
        if delta < 0:
            delta = 0
        meter = (delta / hz) / dt * 100.0
        share = _share_percent(delta, total_delta)
        bucket = grouped.setdefault(comm, [0.0, 0.0, 0])
        bucket[0] += meter
        bucket[1] += share
        bucket[2] += 1
    rows = [
        {
            "name": name,
            "percent": round(meter, 1),
            "share": round(share, 1),
            "count": count,
        }
        for name, (meter, share, count) in grouped.items()
    ]
    rows.sort(key=lambda row: (-row["percent"], row["name"]))
    active = [row for row in rows if row["percent"] > 0]
    # A quiet sample still fills the table. Extra idle commands stay out of name sort.
    if len(active) < 8:
        idle = [row for row in rows if row["percent"] <= 0]
        active.extend(idle[: 8 - len(active)])
    return active[:80], round(busy, 1)


def _pmon_percent(token: str) -> float:
    if token in ("", "-"):
        return 0.0
    try:
        return float(token)
    except ValueError:
        return 0.0


def _gpu_label(pid: int, command: str) -> str:
    try:
        name = Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip()
    except OSError:
        name = ""
    if name:
        return name
    token = command.split()[0] if command else ""
    return Path(token).name or "process"


def _parse_pmon(text: str) -> list[dict]:
    """Max sm across repeated lines of one pid, then sum pids that share a command."""
    best: dict[int, float] = {}
    labels: dict[int, str] = {}
    for line in text.splitlines():
        match = _PMON_ROW.match(line)
        if not match:
            continue
        pid = int(match.group(1))
        percent = _pmon_percent(match.group(2))
        labels[pid] = _gpu_label(pid, match.group(3).strip())
        if percent > best.get(pid, 0.0):
            best[pid] = percent
    grouped: dict[str, list] = {}
    for pid, label in labels.items():
        percent = best.get(pid, 0.0)
        bucket = grouped.setdefault(label, [0.0, 0])
        bucket[0] += percent
        bucket[1] += 1
    rows = [
        {
            "name": name,
            "percent": round(val, 1),
            "share": 0.0,
            "count": count,
        }
        for name, (val, count) in grouped.items()
    ]
    rows.sort(key=lambda row: (-row["percent"], row["name"]))
    return rows[:80]


def _apply_gpu_share(rows: list[dict], util: float | None) -> None:
    """The label is this command's part of the GPU's total load, 0 to 100.

    percent stays the SM sample the LED scale uses. The shares of one sample
    add up to utilization.gpu, the same 0–100 reading as the total bar.
    """
    total = 0.0
    for row in rows:
        total += float(row.get("percent") or 0.0)
    cap = None if util is None else max(0.0, min(100.0, float(util)))
    for row in rows:
        sample = float(row.get("percent") or 0.0)
        if cap is None:
            share = sample
        elif total <= 0 or sample <= 0 or cap <= 0:
            share = 0.0
        else:
            share = sample / total * cap
        if share < 0:
            share = 0.0
        if share > 100:
            share = 100.0
        row["share"] = round(share, 1)


def _gpu_util() -> float | None:
    try:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        out = subprocess.run(
            [_NVIDIA_SMI, "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=1.5,
            check=False,
            env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    line = out.stdout.strip().splitlines()
    if not line:
        return None
    try:
        value = float(line[0].strip().split()[0])
    except ValueError:
        return None
    if value < 0:
        return 0.0
    if value > 100:
        return 100.0
    return value


def _gpu_sample() -> None:
    ok = False
    rows: list[dict] = []
    util = _gpu_util()
    try:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
        # One pmon frame is often all dashes. Three frames a second apart
        # catch a real sm reading without blocking the client thread.
        out = subprocess.run(
            [_NVIDIA_SMI, "pmon", "-c", "3", "-d", "1", "-s", "u"],
            capture_output=True,
            text=True,
            timeout=3.6,
            check=False,
            env=env,
        )
        if out.returncode == 0:
            rows = _parse_pmon(out.stdout)
            _apply_gpu_share(rows, util)
            ok = True
    except (OSError, subprocess.TimeoutExpired):
        ok = False
    with _GPU_LOCK:
        _GPU["running"] = False
        if util is not None:
            _GPU["util"] = util
        if ok and rows:
            _GPU["rows"] = rows
            _GPU["ok"] = True
            _GPU["fail"] = 0
            _GPU["empty"] = 0
        elif ok:
            _GPU["ok"] = True
            _GPU["fail"] = 0
            _GPU["empty"] = int(_GPU["empty"]) + 1
            if _GPU["empty"] >= 2:
                _GPU["rows"] = []
        else:
            _GPU["fail"] = int(_GPU["fail"]) + 1
            if _GPU["fail"] >= 2:
                _GPU["ok"] = False
                _GPU["rows"] = []


def _kick_gpu() -> None:
    with _GPU_LOCK:
        if _GPU["running"]:
            return
        _GPU["running"] = True
    threading.Thread(target=_gpu_sample, name="omaflow-gpu", daemon=True).start()


def processes_snapshot() -> dict:
    """CPU from /proc and GPU from nvidia-smi. Neither reads hwmon or changes poll_rate."""
    try:
        cpu, cpu_total = _cpu_sample()
    except Exception:
        cpu, cpu_total = [], 0.0
    _kick_gpu()
    with _GPU_LOCK:
        return {
            "cpu": cpu,
            "cpuTotal": cpu_total,
            "gpu": list(_GPU["rows"]),
            "gpuTotal": float(_GPU.get("util") or 0.0),
            "gpuOk": bool(_GPU["ok"]),
        }


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
            )
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
