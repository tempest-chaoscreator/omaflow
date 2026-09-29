#!/usr/bin/env python3
"""JSON-line client for coolercontrold on 127.0.0.1.

Speaks HTTP only. It does not open sysfs, USB, or liquidctl.
Sensor reads and fan writes stay on the daemon's poll_rate
(default 1 second). This client never changes that setting.
"""

from __future__ import annotations

import base64
import io
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.cookiejar import CookieJar
from pathlib import Path

BASE = "http://127.0.0.1:11987"
TOKEN_PATH = Path.home() / ".config" / "omaflow" / "coolercontrol.token"
GROUPS_PATH = TOKEN_PATH.with_name("groups.json")
LINKS_PATH = TOKEN_PATH.with_name("links.json")
HIDDEN_PATH = TOKEN_PATH.with_name("hidden.json")
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


def pair(password: str) -> dict:
    """Log in once, mint a revocable Omaflow token, forget the password."""
    if BASE != "http://127.0.0.1:11987":
        return {"ok": False, "status": 0, "error": "pairing is localhost-only", "body": None}
    if not password:
        return {"ok": False, "status": 0, "error": "password required", "body": None}
    jar = CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    basic = base64.b64encode(b"CCAdmin:" + password.encode("utf-8")).decode("ascii")
    login = urllib.request.Request(
        BASE + "/login",
        method="POST",
        headers={"Authorization": "Basic " + basic},
    )
    try:
        opener.open(login, timeout=8).read()
    except urllib.error.HTTPError:
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
    """Upright frame, then turned clockwise by `angle`. The daemon orientation stays 0."""
    from PIL import Image, ImageDraw
    image = Image.new("RGB", (size, size), _LCD_BG)
    draw = ImageDraw.Draw(image)
    ink = _parse_hex(accent)
    ink2 = _parse_hex(accent2 or accent)
    margin = 22
    box = [margin, margin, size - margin - 1, size - margin - 1]
    combo = face in ("cpu-gpu", "cpu-liquid")
    if combo:
        # Pillow measures arcs clockwise from 3 o'clock. Left half, then right half.
        draw.arc(box, start=90, end=270, fill=ink, width=14)
        draw.arc(box, start=270, end=90, fill=ink2, width=14)
    else:
        draw.ellipse(box, outline=ink, width=14)
    left, right = _face_labels(face)
    number = primary if primary else "—"
    if combo:
        other = secondary if secondary else "—"
        number_font = _lcd_font(78)
        label_font = _lcd_font(22)
        _draw_at(draw, size * 0.34, size * 0.40, number, number_font, ink)
        _draw_at(draw, size * 0.66, size * 0.40, other, number_font, ink2)
        _draw_at(draw, size * 0.34, size * 0.62, left, label_font, ink)
        _draw_at(draw, size * 0.66, size * 0.62, right, label_font, ink2)
        draw.line([(size / 2, size * 0.34), (size / 2, size * 0.70)], fill=(250, 252, 251), width=2)
    else:
        number_font = _lcd_font(104)
        label_font = _lcd_font(26)
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
) -> dict:
    token = read_token()
    if not token:
        return {"ok": False, "status": 0, "error": "need-token", "body": None}
    level = max(0, min(100, int(brightness)))
    # The frame already carries the dial angle. A second daemon orientation would turn it again.
    png = render_lcd_png(
        face or "liquid",
        temp_text or "—",
        temp2 or "",
        accent or "#b59790",
        accent2 or "#87a9b0",
        int(angle or 0),
        320,
        "square" if str(shape or "round") == "square" else "round",
        int(width or 0) or None,
        int(height or 0) or None,
    )
    body, content_type = _multipart(
        [("mode", "image"), ("brightness", str(level)), ("orientation", "0")],
        "lcd.png",
        png,
    )
    path = "/devices/" + device + "/settings/" + channel + "/lcd/images"
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
        with urllib.request.urlopen(req, timeout=30) as res:
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
        return {"ok": False, "status": err.code, "error": detail or str(err.reason), "body": None}
    except urllib.error.URLError as err:
        return {"ok": False, "status": 0, "error": str(err.reason), "body": None}
    except Exception as err:  # noqa: BLE001
        return {"ok": False, "status": 0, "error": str(err), "body": None}


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
        with urllib.request.urlopen(req, timeout=8) as res:
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
            with urllib.request.urlopen(req, timeout=None) as res:
                emit({"event": "up"})
                buf = ""
                while not _STOP.is_set():
                    chunk = res.read(4096)
                    if not chunk:
                        break
                    buf += chunk.decode("utf-8", "replace")
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


def main() -> None:
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
        if op == "pair":
            result = pair(str(msg.get("password") or ""))
            result["id"] = msg.get("id")
            emit(result)
            if result.get("ok"):
                emit({"event": "hello", "token": True})
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
            )
            result["id"] = msg.get("id")
            emit(result)
            continue
        if op != "call":
            continue
        result = call(str(msg.get("method") or "GET"), str(msg.get("path") or "/"), msg.get("body"))
        result["id"] = msg.get("id")
        emit(result)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        _STOP.set()
