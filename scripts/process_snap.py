"""One process sample shared by the window and the bar.

coolercontrold already polls temperatures, fans, and the pump once.
Per-process CPU and GPU are not in that daemon. Both Omaflow clients
call snapshot(), and a lock plus this file keeps them on one nvidia-smi.
"""

from __future__ import annotations

import errno
import fcntl
import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path

SNAP_DIR = Path.home() / ".cache" / "omaflow"
_NVIDIA_SMI = "/usr/bin/nvidia-smi"
_LIMIT = 1_000_000
# The window and the bar each poll on their own 2s timer. One published
# measurement covers that interval, so both draw the same rows.
_SAMPLE_HOLD = 2.0
_PMON_ROW = re.compile(
    r"^\s*\d+\s+(\d+)\s+\S+\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(.*\S)\s*$"
)


def _paths() -> tuple[Path, Path]:
    return SNAP_DIR / "processes.json", SNAP_DIR / "processes.lock"


def _user_comm(pid: int) -> str | None:
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
    if delta_ticks <= 0 or total_delta <= 0:
        return 0.0
    return delta_ticks / total_delta * 100.0


def _capture_cpu() -> tuple:
    now = time.time()
    times = _cpu_times()
    total = times[0] if times else None
    idle = times[1] if times else None
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
    return now, total, idle, procs


def _baseline_dump(captured: tuple) -> dict:
    now, total, idle, procs = captured
    packed = {str(pid): [comm, ticks] for pid, (comm, ticks) in procs.items()}
    return {"t": now, "total": total, "idle": idle, "procs": packed}


def _baseline_load(data: object) -> tuple | None:
    if not isinstance(data, dict):
        return None
    try:
        now = float(data.get("t"))
    except (TypeError, ValueError):
        return None
    total = data.get("total")
    idle = data.get("idle")
    try:
        total = None if total is None else int(total)
        idle = None if idle is None else int(idle)
    except (TypeError, ValueError):
        return None
    procs: dict[int, tuple[str, int]] = {}
    raw = data.get("procs")
    if isinstance(raw, dict):
        for key, val in raw.items():
            if not isinstance(val, list) or len(val) < 2:
                continue
            try:
                pid = int(key)
                ticks = int(val[1])
            except (TypeError, ValueError):
                continue
            comm = str(val[0] or "")
            if comm:
                procs[pid] = (comm, ticks)
    return now, total, idle, procs


def _cpu_between(prev: tuple, cur: tuple) -> tuple[list[dict], float] | None:
    now, total, idle, procs = cur
    if prev[1] is None or prev[2] is None or total is None or idle is None:
        return None
    dt = now - float(prev[0])
    if dt <= 0.2:
        return None
    try:
        hz = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    except (OSError, ValueError, KeyError):
        hz = 100
    if hz <= 0:
        hz = 100
    total_delta = int(total) - int(prev[1])
    idle_delta = int(idle) - int(prev[2])
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
    rows.sort(key=lambda row: (-float(row["share"]), -float(row["percent"]), str(row["name"])))
    active = [row for row in rows if float(row["share"]) > 0 or float(row["percent"]) > 0]
    if len(active) < 8:
        quiet = [row for row in rows if float(row["share"]) <= 0 and float(row["percent"]) <= 0]
        active.extend(quiet[: 8 - len(active)])
    return active[:80], round(busy, 1)


def _sample_fresh(snap: dict, now: float) -> bool:
    if not isinstance(snap.get("cpu"), list):
        return False
    try:
        sample_at = float(snap.get("sampleAt") or 0)
    except (TypeError, ValueError):
        return False
    return sample_at > 0 and (now - sample_at) < _SAMPLE_HOLD


def _advance_cpu(snap: dict, cur: tuple) -> tuple[list, float, dict, bool]:
    prev = _baseline_load(snap.get("baseline"))
    old_cpu = snap.get("cpu") if isinstance(snap.get("cpu"), list) else []
    try:
        old_total = float(snap.get("cpuTotal") or 0)
    except (TypeError, ValueError):
        old_total = 0.0
    if prev is None:
        return old_cpu, old_total, _baseline_dump(cur), False
    dt = cur[0] - float(prev[0])
    # A long gap is a new baseline, not a sample. Keeping the old baseline
    # would make every later read look too long and never settle.
    if dt <= 0.2:
        base = snap.get("baseline")
        if not isinstance(base, dict):
            base = _baseline_dump(cur)
        return old_cpu, old_total, base, False
    if dt > 10:
        return old_cpu, old_total, _baseline_dump(cur), False
    sample = _cpu_between(prev, cur)
    if sample is None:
        return old_cpu, old_total, _baseline_dump(cur), False
    rows, total = sample
    return rows, total, _baseline_dump(cur), True


def _read_snap() -> dict:
    path, _lock = _paths()
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    except OSError:
        return {}
    try:
        chunks = []
        size = 0
        while size <= _LIMIT:
            part = os.read(fd, 65536)
            if not part:
                break
            size += len(part)
            chunks.append(part)
        if size > _LIMIT:
            return {}
        data = json.loads(b"".join(chunks).decode("utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return {}
    finally:
        os.close(fd)
    return data if isinstance(data, dict) else {}


def _write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    sent = 0
    while sent < len(view):
        wrote = os.write(fd, view[sent:])
        if wrote <= 0:
            raise OSError(errno.EIO, "short write")
        sent += wrote


def _write_snap(data: dict) -> None:
    SNAP_DIR.mkdir(parents=True, mode=0o700, exist_ok=True)
    blob = json.dumps(data, separators=(",", ":")).encode("utf-8")
    if len(blob) > _LIMIT:
        return
    path, _lock = _paths()
    tmp = SNAP_DIR / "processes.json.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        fd = os.open(tmp, flags, 0o600)
    except OSError:
        return
    try:
        try:
            _write_all(fd, blob)
        except OSError:
            return
    finally:
        os.close(fd)
    try:
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except OSError:
        return


def _lock():
    SNAP_DIR.mkdir(parents=True, mode=0o700, exist_ok=True)
    _path, lock = _paths()
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def _unlock(fd: int) -> None:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _public(snap: dict) -> dict:
    cpu = snap.get("cpu") if isinstance(snap.get("cpu"), list) else []
    gpu = snap.get("gpu") if isinstance(snap.get("gpu"), list) else []
    try:
        cpu_total = float(snap.get("cpuTotal") or 0)
    except (TypeError, ValueError):
        cpu_total = 0.0
    try:
        gpu_total = float(snap.get("gpuTotal") or 0)
    except (TypeError, ValueError):
        gpu_total = 0.0
    return {
        "cpu": cpu,
        "cpuTotal": cpu_total,
        "gpu": gpu,
        "gpuTotal": gpu_total,
        "gpuOk": snap.get("gpuOk") is not False,
    }


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
        {"name": name, "percent": round(val, 1), "share": 0.0, "count": count}
        for name, (val, count) in grouped.items()
    ]
    rows.sort(key=lambda row: (-float(row["percent"]), str(row["name"])))
    return rows[:80]


def _apply_gpu_share(rows: list[dict], util: float | None) -> None:
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


def _gpu_worker() -> None:
    ok = False
    rows: list[dict] = []
    util = _gpu_util()
    try:
        env = os.environ.copy()
        env["LC_ALL"] = "C"
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
    fd = _lock()
    try:
        snap = _read_snap()
        if util is not None:
            snap["gpuTotal"] = util
        if ok and rows:
            snap["gpu"] = rows
            snap["gpuOk"] = True
            snap["gpuFail"] = 0
            snap["gpuEmpty"] = 0
        elif ok:
            snap["gpuOk"] = True
            snap["gpuFail"] = 0
            snap["gpuEmpty"] = int(snap.get("gpuEmpty") or 0) + 1
            if int(snap["gpuEmpty"]) >= 2:
                snap["gpu"] = []
        else:
            snap["gpuFail"] = int(snap.get("gpuFail") or 0) + 1
            if int(snap["gpuFail"]) >= 2:
                snap["gpuOk"] = False
                snap["gpu"] = []
        snap["gpuAt"] = time.time()
        snap["gpuRunning"] = 0.0
        _write_snap(snap)
    finally:
        _unlock(fd)


def snapshot() -> dict:
    """Latest shared process sample. Starts one GPU read when the last one is stale."""
    cur = _capture_cpu()
    start_gpu = False
    fd = _lock()
    try:
        snap = _read_snap()
        now = time.time()
        fresh = _sample_fresh(snap, now)
        try:
            gpu_at = float(snap.get("gpuAt") or 0)
        except (TypeError, ValueError):
            gpu_at = 0.0
        try:
            gpu_running = float(snap.get("gpuRunning") or 0)
        except (TypeError, ValueError):
            gpu_running = 0.0
        start_gpu = (now - gpu_at) >= 2.0 and (now - gpu_running) >= 4.0
        if not fresh:
            cpu, cpu_total, baseline, measured = _advance_cpu(snap, cur)
            snap["baseline"] = baseline
            snap["cpu"] = cpu
            snap["cpuTotal"] = cpu_total
            if measured:
                snap["sampleAt"] = now
        if start_gpu:
            snap["gpuRunning"] = now
        if not fresh or start_gpu:
            _write_snap(snap)
        body = _public(snap)
    finally:
        _unlock(fd)
    if start_gpu:
        threading.Thread(target=_gpu_worker, name="omaflow-gpu", daemon=True).start()
    return body
