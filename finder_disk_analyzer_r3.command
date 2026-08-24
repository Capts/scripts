#!/bin/bash
set -euo pipefail

# Finder Disk Analyzer disposable launcher
# - Creates a temporary virtual environment
# - Keeps pip cache / Python bytecode in the same temporary root
# - Prompts before installing any third-party Python packages
# - Runs the analyzer rooted at the folder from which you launched it
# - Removes the entire temporary root on exit / Ctrl+C / TERM / HUP

APP_VERSION="2026.08.25-r3"
START_DIR="$(pwd -P)"
TMP_BASE="${TMPDIR:-/tmp}"
TMP_ROOT="$(mktemp -d "${TMP_BASE%/}/finder-disk-analyzer.XXXXXX")"
VENV_DIR="$TMP_ROOT/venv"
APP_FILE="$TMP_ROOT/finder_disk_analyzer.py"

cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP

    rm -rf -- "$TMP_ROOT"
    printf '\nTemporary Finder Disk Analyzer environment removed.\n'

    # If the app actually crashed, keep a double-clicked Terminal window open
    # long enough for the error to be read. Normal exit/Ctrl+C stays immediate.
    case "$rc" in
        0|129|130|143) ;;
        *)
            if [[ -t 0 ]]; then
                printf '\nThe analyzer exited with error code %s.\n' "$rc"
                read -r -p 'Press Enter to close...' _ || true
            fi
            ;;
    esac

    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$TMP_ROOT/tmp" "$TMP_ROOT/pip-cache" "$TMP_ROOT/pycache"

export PIP_CACHE_DIR="$TMP_ROOT/pip-cache"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONPYCACHEPREFIX="$TMP_ROOT/pycache"

# Add any future third-party dependencies here.
# Example:
# REQUIRED_PACKAGES=("pymupdf==1.26.4")
REQUIRED_PACKAGES=()

printf 'Finder Disk Analyzer %s\n' "$APP_VERSION"
printf 'Start folder: %s\n' "$START_DIR"
printf 'Temporary environment: %s\n\n' "$TMP_ROOT"

python3 -m venv "$VENV_DIR"
PYTHON="$VENV_DIR/bin/python"

if (( ${#REQUIRED_PACKAGES[@]} > 0 )); then
    printf 'The analyzer needs these temporary Python packages:\n'
    printf '  - %s\n' "${REQUIRED_PACKAGES[@]}"
    printf '\nThey will exist only inside:\n  %s\n' "$VENV_DIR"

    read -r -p 'Install them into the temporary environment? [y/N] ' reply
    case "$reply" in
        y|Y|yes|YES|Yes)
            "$PYTHON" -m pip install --no-input "${REQUIRED_PACKAGES[@]}"
            ;;
        *)
            printf 'Cancelled. No packages were installed.\n'
            exit 1
            ;;
    esac
else
    printf 'No third-party Python packages are required for this version.\n'
    printf 'PDF preview uses the browser; CSV/TXT preview uses Python standard-library modules.\n\n'
fi

cat > "$APP_FILE" <<'PYAPP'
import os, sys, json, time, shutil, subprocess, webbrowser, http.server, socketserver, urllib.parse, re, csv, threading
from concurrent.futures import ThreadPoolExecutor

PORT = 8910
APP_VERSION = "2026.08.25-r3"
HOME_DIR = os.path.realpath(os.path.expanduser("~"))
START_DIR = os.path.realpath(os.environ.get("FINDER_START_DIR", os.getcwd()))
if not os.path.isdir(START_DIR):
    START_DIR = HOME_DIR

def resolve_directory(path):
    """Resolve a requested folder without ever passing a missing path to disk_usage()."""
    raw = str(path or "").strip()

    if not raw:
        return START_DIR

    raw = os.path.expanduser(raw)

    # Repair malformed Favorites paths produced by older builds.
    legacy_favorite = raw.rstrip("/")
    if legacy_favorite in {"/Desktop", "/Documents", "/Downloads"}:
        raw = os.path.join(HOME_DIR, legacy_favorite.lstrip("/"))

    if not os.path.isabs(raw):
        raw = os.path.join(START_DIR, raw)

    resolved = os.path.realpath(os.path.abspath(raw))
    if os.path.isdir(resolved):
        return resolved

    # Never return a path that does not exist.
    for fallback in (START_DIR, HOME_DIR, "/"):
        if os.path.isdir(fallback):
            return os.path.realpath(fallback)

    raise FileNotFoundError("No usable scan directory is available")

MAX_WORKERS = min(16, max(4, (os.cpu_count() or 4) * 2))
EXECUTOR = ThreadPoolExecutor(max_workers=MAX_WORKERS)
SEARCH_RESULT_LIMIT = 250
TEXT_PREVIEW_LIMIT = 256 * 1024
CSV_PREVIEW_ROWS = 100
CSV_PREVIEW_COLS = 40

SIZE_CACHE = {}
CACHE_TTL_SECONDS = 600

EXT_MAP = {
    'Video': {'.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v'},
    'Audio': {'.mp3', '.wav', '.aac', '.flac', '.m4a', '.ogg'},
    'Images': {'.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.heic', '.raw'},
    'Dev/Code': {'.js', '.py', '.ts', '.cpp', '.c', '.java', '.go', '.rs', '.json', '.html', '.css', '.m'},
    'Archives': {'.zip', '.tar', '.gz', '.7z', '.rar', '.dmg', '.iso'},
    'Docs': {'.pdf', '.docx', '.xlsx', '.pptx', '.txt', '.md', '.csv'}
}

PROTECTED_PATHS = {
    '/', '/System', '/Library', '/usr', '/bin', '/sbin', '/var', '/private', '/etc',
    '/Applications', '/Volumes', '/Network', '/opt', '/dev',
    os.path.expanduser('~'),
    os.path.expanduser('~/Library'),
    os.path.expanduser('~/Desktop'),
    os.path.expanduser('~/Documents'),
    os.path.expanduser('~/Downloads')
}

def is_protected_path(target_path):
    try:
        abs_path = os.path.realpath(os.path.abspath(target_path))
        return abs_path in PROTECTED_PATHS
    except Exception:
        return True

def fmt(b):
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024: return f"{b:.2f} {u}"
        b /= 1024

def get_ext_category(filename):
    ext = os.path.splitext(filename)[1].lower()
    for cat, exts in EXT_MAP.items():
        if ext in exts: return cat
    return 'Other'

def move_to_trash(target_path):
    if is_protected_path(target_path):
        return False, "Access Denied: Protected System or Core User Path."

    try:
        abs_path = os.path.abspath(target_path)
        cmd = ['osascript', '-e', f'tell application "Finder" to delete POSIX file "{abs_path}"']
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0:
            return True, "Item moved to Trash successfully."
        else:
            return False, res.stderr.strip() or "macOS Finder prevented deletion of this item."
    except Exception as e:
        return False, str(e)

def fast_dir_sz(p, bypass_cache=False):
    p = os.path.realpath(p)
    now = time.time()
    if not bypass_cache and p in SIZE_CACHE:
        cached_sz, timestamp = SIZE_CACHE[p]
        if now - timestamp < CACHE_TTL_SECONDS:
            return cached_sz

    total = 0

    def ignore_walk_error(_err):
        pass

    for dirpath, dirnames, filenames in os.walk(
        p, topdown=True, followlinks=False, onerror=ignore_walk_error
    ):
        # Never descend into directory symlinks.
        dirnames[:] = [
            name for name in dirnames
            if not os.path.islink(os.path.join(dirpath, name))
        ]

        for name in filenames:
            file_path = os.path.join(dirpath, name)
            try:
                if not os.path.islink(file_path):
                    total += os.path.getsize(file_path)
            except OSError:
                pass

    SIZE_CACHE[p] = (total, now)
    return total

def scan_single_entry(args):
    entry, bypass_cache = args
    try:
        is_directory = entry.is_dir(follow_symlinks=False)
        if entry.is_file(follow_symlinks=False):
            sz = entry.stat(follow_symlinks=False).st_size
            cat = get_ext_category(entry.name)
        elif is_directory:
            sz = fast_dir_sz(entry.path, bypass_cache)
            cat = 'Folder'
        else:
            sz = 0
            cat = 'Other'
            
        protected = is_protected_path(entry.path)

        return {
            "name": entry.name,
            "path": entry.path,
            "size": sz,
            "fmt": fmt(sz),
            "is_dir": is_directory,
            "category": cat,
            "protected": protected
        }
    except Exception:
        return None

def fast_parallel_scan(target, bypass_cache=False):
    entries = []
    try:
        with os.scandir(target) as it:
            entries = [(e, bypass_cache) for e in it]
    except Exception:
        return [], {}

    results = list(EXECUTOR.map(scan_single_entry, entries))
    valid_items = [r for r in results if r is not None]
    valid_items.sort(key=lambda x: x["size"], reverse=True)

    cats = {}
    for item in valid_items:
        c = item["category"]
        cats[c] = cats.get(c, 0) + item["size"]

    return valid_items, cats

def recursive_file_search(target, query, limit=SEARCH_RESULT_LIMIT):
    target = resolve_directory(target)
    needle = (query or "").strip().casefold()
    if not needle or not os.path.isdir(target):
        return [], False

    results = []
    truncated = False

    def ignore_walk_error(_err):
        pass

    for dirpath, dirnames, filenames in os.walk(target, topdown=True, followlinks=False, onerror=ignore_walk_error):
        # Avoid following directory symlinks even if a platform reports them oddly.
        dirnames[:] = [
            d for d in dirnames
            if not os.path.islink(os.path.join(dirpath, d))
        ]

        for name in filenames:
            full_path = os.path.join(dirpath, name)
            rel_path = os.path.relpath(full_path, target)
            haystack = f"{name}\n{rel_path}".casefold()

            if needle not in haystack:
                continue

            try:
                size = os.path.getsize(full_path)
            except OSError:
                size = 0

            results.append({
                "name": name,
                "path": full_path,
                "relative_path": rel_path,
                "size": size,
                "fmt": fmt(size),
                "is_dir": False,
                "category": get_ext_category(name),
                "protected": is_protected_path(full_path),
            })

            if len(results) >= limit:
                truncated = True
                break

        if truncated:
            break

    results.sort(key=lambda x: (x["name"].casefold(), x["relative_path"].casefold()))
    return results, truncated


def text_or_csv_preview(file_path):
    ext = os.path.splitext(file_path)[1].lower()

    if ext == ".txt":
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read(TEXT_PREVIEW_LIMIT + 1)
        truncated = len(content) > TEXT_PREVIEW_LIMIT
        if truncated:
            content = content[:TEXT_PREVIEW_LIMIT]
        return {
            "kind": "text",
            "content": content,
            "truncated": truncated,
        }

    if ext == ".csv":
        rows = []
        truncated = False
        try:
            csv.field_size_limit(max(csv.field_size_limit(), 10 * 1024 * 1024))
        except Exception:
            pass

        with open(file_path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
            reader = csv.reader(f)
            for index, row in enumerate(reader):
                if index >= CSV_PREVIEW_ROWS:
                    truncated = True
                    break
                rows.append([cell[:2000] for cell in row[:CSV_PREVIEW_COLS]])

        return {
            "kind": "csv",
            "rows": rows,
            "truncated": truncated,
        }

    raise ValueError("Unsupported preview type")


class UltimateSpaceHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/api/file":
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get("path", [""])[0]
            if os.path.isfile(file_path):
                ext = os.path.splitext(file_path)[1].lower()
                mime_types = {
                    '.mp4': 'video/mp4', '.webm': 'video/webm', '.mov': 'video/quicktime',
                    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
                    '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp',
                    '.pdf': 'application/pdf', '.txt': 'text/plain; charset=utf-8',
                    '.csv': 'text/csv; charset=utf-8'
                }
                mime = mime_types.get(ext, 'application/octet-stream')
                file_size = os.path.getsize(file_path)
                
                range_header = self.headers.get('Range', None)
                if range_header:
                    match = re.search(r'bytes=(\d+)-(\d*)', range_header)
                    if match:
                        first_byte = int(match.group(1))
                        last_byte = int(match.group(2)) if match.group(2) else file_size - 1
                        length = last_byte - first_byte + 1
                        
                        self.send_response(206)
                        self.send_header('Content-Type', mime)
                        self.send_header('Accept-Ranges', 'bytes')
                        self.send_header('Content-Range', f'bytes {first_byte}-{last_byte}/{file_size}')
                        self.send_header('Content-Length', str(length))
                        self.end_headers()
                        
                        with open(file_path, 'rb') as f:
                            f.seek(first_byte)
                            self.wfile.write(f.read(length))
                        return

                try:
                    self.send_response(200)
                    self.send_header("Content-type", mime)
                    self.send_header("Accept-Ranges", "bytes")
                    self.send_header("Content-Length", str(file_size))
                    self.end_headers()
                    with open(file_path, 'rb') as f:
                        shutil.copyfileobj(f, self.wfile)
                    return
                except Exception:
                    pass
            self.send_error(404, "File Not Found")
            return

        if parsed.path == "/api/preview":
            query = urllib.parse.parse_qs(parsed.query)
            file_path = query.get("path", [""])[0]

            try:
                if not os.path.isfile(file_path):
                    raise FileNotFoundError(file_path)

                payload = text_or_csv_preview(file_path)
                self.send_response(200)
            except ValueError as e:
                payload = {"error": str(e)}
                self.send_response(415)
            except Exception as e:
                payload = {"error": str(e)}
                self.send_response(404)

            self.send_header("Content-type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode("utf-8"))
            return

        if parsed.path == "/api/search":
            query_args = urllib.parse.parse_qs(parsed.query)
            target = resolve_directory(query_args.get("path", [START_DIR])[0])
            search_query = query_args.get("q", [""])[0]

            try:
                results, truncated = recursive_file_search(target, search_query)
                payload = {
                    "current": target,
                    "query": search_query,
                    "items": results,
                    "truncated": truncated,
                }
                self.send_response(200)
            except Exception as e:
                payload = {"error": str(e), "items": [], "truncated": False}
                self.send_response(500)

            self.send_header("Content-type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode("utf-8"))
            return

        if parsed.path.startswith("/api/scan"):
            query = urllib.parse.parse_qs(parsed.query)
            requested = query.get("path", [START_DIR])[0]
            bypass_cache = query.get("refresh", ["false"])[0] == "true"

            try:
                target = resolve_directory(requested)
                items, cat_breakdown = fast_parallel_scan(target, bypass_cache=bypass_cache)
                total_disk, used_disk, free_disk = shutil.disk_usage(target)
                payload = {
                    "current": target,
                    "requested": requested,
                    "home_path": HOME_DIR,
                    "start_path": START_DIR,
                    "app_version": APP_VERSION,
                    "items": items[:35],
                    "categories": cat_breakdown,
                    "disk": {
                        "total": total_disk,
                        "used": used_disk,
                        "free": free_disk,
                        "total_fmt": fmt(total_disk),
                        "used_fmt": fmt(used_disk),
                        "free_fmt": fmt(free_disk),
                        "pct_used": round((used_disk / total_disk) * 100, 1) if total_disk else 0
                    }
                }
                self.send_response(200)
            except Exception as e:
                payload = {
                    "error": f"Scan failed: {e}",
                    "requested": requested,
                    "home_path": HOME_DIR,
                    "start_path": START_DIR,
                    "app_version": APP_VERSION,
                }
                self.send_response(500)

            self.send_header("Content-type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode('utf-8'))
            return

        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.end_headers()
        html = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Finder Disk Analyzer</title>
    <script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
    <style>
        * { box-sizing: border-box; }
        
        :root {
            --bg-body: #e0e0e0;
            --window-bg: rgba(255, 255, 255, 0.88);
            --toolbar-bg: rgba(246, 246, 246, 0.8);
            --border-color: rgba(0, 0, 0, 0.12);
            --sidebar-bg: rgba(238, 238, 241, 0.6);
            --sidebar-text: #2c2c2c;
            --sidebar-hover: rgba(0,0,0,0.05);
            --content-bg: #ffffff;
            --stats-bg: #f9f9fb;
            --text-main: #1c1c1e;
            --text-muted: #8e8e93;
            --row-hover: #f0f7ff;
            --crumb-bg: #f2f2f7;
            --seg-bg: rgba(0, 0, 0, 0.05);
            --seg-btn-bg: #ffffff;
            --preview-bg: #f4f4f7;
        }

        body.dark-mode {
            --bg-body: #1e1e1e;
            --window-bg: rgba(38, 38, 38, 0.88);
            --toolbar-bg: rgba(45, 45, 45, 0.8);
            --border-color: rgba(255, 255, 255, 0.12);
            --sidebar-bg: rgba(30, 30, 30, 0.6);
            --sidebar-text: #e5e5ea;
            --sidebar-hover: rgba(255,255,255,0.08);
            --content-bg: #1c1c1e;
            --stats-bg: #2c2c2e;
            --text-main: #f2f2f7;
            --text-muted: #98989d;
            --row-hover: #2c3e50;
            --crumb-bg: #2c2c2e;
            --seg-bg: rgba(255, 255, 255, 0.1);
            --seg-btn-bg: #3a3a3c;
            --preview-bg: #18181a;
        }

        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; background: var(--bg-body); height: 100vh; display: flex; align-items: center; justify-content: center; overflow: hidden; user-select: none; transition: background 0.3s; }
        
        .finder-window { width: 92vw; height: 90vh; background: var(--window-bg); backdrop-filter: blur(25px); -webkit-backdrop-filter: blur(25px); border-radius: 12px; box-shadow: 0 25px 50px rgba(0,0,0,0.3), 0 0 0 1px var(--border-color); display: flex; flex-direction: column; overflow: hidden; }
        
        .toolbar { height: 52px; background: var(--toolbar-bg); border-bottom: 1px solid var(--border-color); display: flex; align-items: center; padding: 0 16px; gap: 16px; flex-shrink: 0; }
        .window-controls { display: flex; gap: 8px; margin-right: 8px; }
        .dot { width: 12px; height: 12px; border-radius: 50%; }
        .dot-close { background: #ff5f56; border: 1px solid #e0443e; }
        .dot-min { background: #ffbd2e; border: 1px solid #dea123; }
        .dot-max { background: #27c93f; border: 1px solid #1aab29; }
        
        .nav-controls { display: flex; gap: 6px; }
        .icon-btn { background: var(--seg-btn-bg); border: 1px solid var(--border-color); border-radius: 6px; padding: 5px 10px; cursor: pointer; display: flex; align-items: center; justify-content: center; box-shadow: 0 1px 2px rgba(0,0,0,0.05); color: var(--text-main); }
        .icon-btn:hover { opacity: 0.8; }
        .icon-btn svg { width: 14px; height: 14px; fill: currentColor; }
        .shutdown-btn { margin-left: 2px; border: 1px solid rgba(255,59,48,.35); background: rgba(255,59,48,.10); color: #ff3b30; border-radius: 7px; padding: 5px 9px; font-size: 11px; font-weight: 700; cursor: pointer; }
        .shutdown-btn:hover { background: rgba(255,59,48,.18); }

        .segment-control { display: flex; background: var(--seg-bg); padding: 2px; border-radius: 6px; }
        .seg-btn { border: none; background: transparent; padding: 4px 12px; font-size: 12px; font-weight: 500; border-radius: 4px; cursor: pointer; color: var(--text-muted); }
        .seg-btn.active { background: var(--seg-btn-bg); color: var(--text-main); box-shadow: 0 1px 3px rgba(0,0,0,0.12); font-weight: 600; }

        .window-title { flex-grow: 1; text-align: center; font-size: 13px; font-weight: 600; color: var(--text-main); min-width: 120px; }
        .search-box { width: min(320px, 28vw); position: relative; flex-shrink: 0; }
        .search-input { width: 100%; height: 30px; border-radius: 7px; border: 1px solid var(--border-color); background: var(--seg-btn-bg); color: var(--text-main); padding: 0 10px 0 30px; outline: none; font-size: 12px; }
        .search-input:focus { border-color: #007aff; box-shadow: 0 0 0 2px rgba(0,122,255,.18); }
        .search-icon { position: absolute; left: 9px; top: 7px; width: 15px; height: 15px; fill: var(--text-muted); pointer-events: none; }

        .main-container { display: flex; flex-grow: 1; overflow: hidden; }
        
        .sidebar { width: 190px; background: var(--sidebar-bg); border-right: 1px solid var(--border-color); padding: 12px 8px; flex-shrink: 0; display: flex; flex-direction: column; justify-content: space-between; }
        .sidebar-section { margin-bottom: 16px; }
        .sidebar-title { font-size: 11px; font-weight: 700; color: var(--text-muted); padding: 4px 10px; text-transform: uppercase; }
        .sidebar-item { display: flex; align-items: center; gap: 8px; padding: 6px 10px; border-radius: 6px; font-size: 13px; font-weight: 500; color: var(--sidebar-text); cursor: pointer; }
        .sidebar-item:hover { background: var(--sidebar-hover); }
        .sidebar-item.active { background: #007aff; color: white; }
        .sidebar-item svg { width: 16px; height: 16px; fill: currentColor; }

        .content-area { flex-grow: 1; display: flex; flex-direction: column; background: var(--content-bg); overflow: hidden; }

        .stats-strip { background: var(--stats-bg); border-bottom: 1px solid var(--border-color); padding: 12px 20px; display: flex; flex-direction: column; gap: 8px; flex-shrink: 0; }
        .stats-top { display: flex; justify-content: space-between; align-items: center; font-size: 12px; font-weight: 600; color: var(--text-main); }
        .disk-bar-bg { background: rgba(0,0,0,0.1); height: 10px; border-radius: 5px; overflow: hidden; display: flex; }
        .disk-bar-fill { height: 100%; background: linear-gradient(90deg, #34c759, #ff9500, #ff3b30); }
        .cat-bar { display: flex; height: 8px; border-radius: 4px; overflow: hidden; background: rgba(0,0,0,0.1); margin-top: 4px; }
        .cat-seg { height: 100%; }
        .cat-legend { display: flex; flex-wrap: wrap; gap: 10px; font-size: 11px; color: var(--text-muted); }
        .legend-item { display: flex; align-items: center; gap: 4px; }
        .legend-dot { width: 8px; height: 8px; border-radius: 50%; }

        .breadcrumb-bar { height: 28px; background: var(--crumb-bg); border-bottom: 1px solid var(--border-color); display: flex; align-items: center; padding: 0 16px; font-size: 12px; color: var(--text-muted); gap: 6px; flex-shrink: 0; }
        .crumb { cursor: pointer; color: #007aff; font-weight: 500; }
        .crumb:hover { text-decoration: underline; }
        .crumb:last-child { color: var(--text-main); font-weight: 600; cursor: default; text-decoration: none; }

        .workspace-split { display: flex; flex: 1 1 0; min-height: 0; overflow: hidden; position: relative; }

        .view-container { flex: 1 1 0; min-width: 0; min-height: 0; overflow-y: auto; position: relative; }
        
        .list-header { display: flex; padding: 8px 16px; border-bottom: 1px solid var(--border-color); font-size: 11px; font-weight: 700; color: var(--text-muted); background: var(--stats-bg); position: sticky; top: 0; z-index: 2; }
        .col-name { flex-grow: 1; min-width: 180px; }
        .col-bar { width: 140px; }
        .col-size { width: 90px; text-align: right; }
        .col-action { width: 80px; text-align: right; }

        .row-item { display: flex; align-items: center; padding: 8px 16px; border-bottom: 1px solid var(--border-color); font-size: 13px; color: var(--text-main); cursor: pointer; }
        .row-item:hover { background: var(--row-hover); }
        .row-item.selected { background: #007aff !important; color: white !important; }
        .row-item.selected .file-icon { fill: white !important; }
        .row-item.selected .col-size { color: white !important; }
        
        .file-icon { width: 18px; height: 18px; margin-right: 8px; flex-shrink: 0; }

        .visual-bar-bg { background: rgba(0,0,0,0.1); height: 8px; border-radius: 4px; overflow: hidden; margin-right: 12px; }
        .visual-bar-fill { height: 100%; border-radius: 4px; }
        .fill-dir { background: #ff9500; }
        .fill-file { background: #007aff; }

        .btn-trash { background: #ff3b30; border: none; color: white; padding: 4px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; cursor: pointer; }
        .btn-trash:hover { background: #d70015; }
        .btn-trash:disabled { background: #c7c7cc; cursor: not-allowed; opacity: 0.6; }

        #sunburst-wrapper { display: none; width: 100%; height: 100%; padding: 10px; }

        .preview-pane { width: 420px; background: var(--preview-bg); border-left: 1px solid var(--border-color); padding: 16px; display: none; flex-direction: column; align-items: center; gap: 16px; flex-shrink: 0; overflow-y: auto; }
        .preview-pane.active { display: flex; }
        .preview-header { width: 100%; display: flex; justify-content: space-between; align-items: center; }
        .preview-title { font-size: 12px; font-weight: 700; color: var(--text-muted); text-transform: uppercase; }
        .preview-close { cursor: pointer; font-size: 16px; color: var(--text-muted); border: none; background: transparent; }

        .preview-media-container { width: 100%; max-height: 420px; border-radius: 8px; overflow: auto; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,0.2); }
        .preview-media-container img, .preview-media-container video { max-width: 100%; max-height: 420px; object-fit: contain; }
        .preview-media-container iframe { width: 100%; height: 420px; border: 0; background: white; }
        .text-preview { margin: 0; width: 100%; min-height: 220px; max-height: 420px; overflow: auto; padding: 12px; white-space: pre-wrap; overflow-wrap: anywhere; user-select: text; text-align: left; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; color: var(--text-main); background: var(--content-bg); }
        .csv-preview-wrap { width: 100%; max-height: 420px; overflow: auto; background: var(--content-bg); }
        .csv-preview-table { border-collapse: collapse; width: max-content; min-width: 100%; font-size: 11px; color: var(--text-main); user-select: text; }
        .csv-preview-table th, .csv-preview-table td { border: 1px solid var(--border-color); padding: 5px 7px; text-align: left; max-width: 240px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .csv-preview-table th { position: sticky; top: 0; background: var(--stats-bg); z-index: 1; }
        .search-subpath { display:block; margin-top:2px; font-size:10px; color:var(--text-muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

        .preview-meta { width: 100%; display: flex; flex-direction: column; gap: 8px; font-size: 12px; color: var(--text-main); }
        .meta-row { display: flex; justify-content: space-between; border-bottom: 1px solid var(--border-color); padding-bottom: 4px; }
        .meta-label { color: var(--text-muted); font-weight: 500; }
        .meta-value { font-weight: 600; word-break: break-all; text-align: right; max-width: 180px; }

        .status-bar { height: 24px; background: var(--stats-bg); border-top: 1px solid var(--border-color); display: flex; align-items: center; justify-content: center; font-size: 11px; color: var(--text-muted); flex-shrink: 0; }

        .loading-view { display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 180px; color: var(--text-muted); gap: 12px; }
        .loading-overlay { position: absolute; inset: 0; z-index: 100; display: none; align-items: center; justify-content: center; background: color-mix(in srgb, var(--content-bg) 88%, transparent); backdrop-filter: blur(2px); -webkit-backdrop-filter: blur(2px); }
        .loading-overlay.active { display: flex; }
        .loading-box { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; color: var(--text-muted); font-size: 13px; font-weight: 500; text-align: center; }
        .spinner { width: 28px; height: 28px; border: 3px solid var(--border-color); border-top-color: #007aff; border-radius: 50%; animation: spin 0.8s linear infinite; }
        @keyframes spin { 100% { transform: rotate(360deg); } }
    </style>
</head>
<body>

<div class="finder-window">
    <div class="toolbar">
        <div class="window-controls">
            <div class="dot dot-close" onclick="shutdownApp()" title="Stop analyzer" style="cursor:pointer;"></div>
            <div class="dot dot-min"></div>
            <div class="dot dot-max"></div>
        </div>
        <div class="nav-controls">
            <button class="icon-btn" onclick="loadPath(currentPath, true)" title="Refresh Folder">
                <svg viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
            </button>
            <button class="icon-btn" onclick="toggleDarkMode()" title="Toggle Dark/Light Mode">
                <svg viewBox="0 0 24 24"><path d="M12 3c-4.97 0-9 4.03-9 9s4.03 9 9 9 9-4.03 9-9c0-.46-.04-.92-.1-1.36-.98 1.37-2.58 2.26-4.4 2.26-2.98 0-5.4-2.42-5.4-5.4 0-1.81.89-3.42 2.26-4.4-.44-.06-.9-.1-1.36-.1z"/></svg>
            </button>
            <button class="shutdown-btn" onclick="shutdownApp()" title="Stop server and end launcher">Shutdown</button>
        </div>
        <div class="segment-control">
            <button class="seg-btn active" id="btn-list" onclick="setView('list')">List</button>
            <button class="seg-btn" id="btn-sunburst" onclick="setView('sunburst')">Sunburst Chart</button>
        </div>
        <div class="search-box">
            <svg class="search-icon" viewBox="0 0 24 24"><path d="M9.5 3a6.5 6.5 0 1 0 3.98 11.64L19.85 21 21 19.85l-6.36-6.37A6.5 6.5 0 0 0 9.5 3zm0 2a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9z"/></svg>
            <input class="search-input" id="recursive-search" type="search" placeholder="Search this folder recursively" autocomplete="off">
        </div>
        <div class="window-title" id="win-title">Loading Finder...</div>
    </div>

    <div class="main-container">
        <div class="sidebar">
            <div class="sidebar-section">
                <div class="sidebar-title">Favorites</div>
                <div class="sidebar-item" id="side-home" onclick="goHome()">
                    <svg viewBox="0 0 24 24"><path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"/></svg> Home
                </div>
                <div class="sidebar-item" onclick="loadPath(homePath + '/Desktop')">
                    <svg viewBox="0 0 24 24"><path d="M20 3H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 12H4V5h16v10zM5 18h14v2H5z"/></svg> Desktop
                </div>
                <div class="sidebar-item" onclick="loadPath(homePath + '/Documents')">
                    <svg viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg> Documents
                </div>
                <div class="sidebar-item" onclick="loadPath(homePath + '/Downloads')">
                    <svg viewBox="0 0 24 24"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg> Downloads
                </div>
            </div>
            <div class="sidebar-section">
                <div class="sidebar-title">Locations</div>
                <div class="sidebar-item" onclick="loadPath('/')">
                    <svg viewBox="0 0 24 24"><path d="M20 6H4c-1.1 0-1.99.9-1.99 2L2 16c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 10H4V8h16v8z"/></svg> Macintosh HD
                </div>
            </div>
        </div>

        <div class="content-area">
            <div class="stats-strip">
                <div class="stats-top">
                    <span>Macintosh HD Storage</span>
                    <span id="disk-stats-text">-- / --</span>
                </div>
                <div class="disk-bar-bg">
                    <div class="disk-bar-fill" id="disk-bar-fill" style="width: 0%"></div>
                </div>
                <div class="cat-bar" id="cat-bar"></div>
                <div class="cat-legend" id="cat-legend"></div>
            </div>

            <div class="breadcrumb-bar" id="crumbs">/</div>

            <div class="workspace-split">
                <div class="loading-overlay" id="loading-overlay">
                    <div class="loading-box">
                        <div class="spinner"></div>
                        <span id="loading-text">Scanning files & folders...</span>
                    </div>
                </div>
                <div class="view-container" id="view-container">
                    <div id="content-list">
                        <div class="list-header">
                            <div class="col-name">Name</div>
                            <div class="col-bar">Storage Allocation</div>
                            <div class="col-size">Size</div>
                            <div class="col-action">Action</div>
                        </div>
                        <div id="row-items"></div>
                    </div>
                    <div id="sunburst-wrapper"></div>
                </div>

                <div class="preview-pane" id="preview-pane">
                    <div class="preview-header">
                        <span class="preview-title">Quick Look</span>
                        <button class="preview-close" onclick="closePreview()">✕</button>
                    </div>
                    <div class="preview-media-container" id="preview-media"></div>
                    <div class="preview-meta" id="preview-meta"></div>
                </div>
            </div>

            <div class="status-bar" id="status-bar">0 items</div>
        </div>
    </div>
</div>

<script>
    let currentPath = __START_PATH_JSON__;
    let homePath = __HOME_PATH_JSON__;
    let currentData = null;
    let activeView = "list";
    let selectedItem = null;
    let searchTimer = null;

    function escapeHtml(value) {
        return String(value ?? "")
            .replaceAll("&", "&amp;")
            .replaceAll("<", "&lt;")
            .replaceAll(">", "&gt;")
            .replaceAll('"', "&quot;")
            .replaceAll("'", "&#039;");
    }

    async function shutdownApp() {
        if (!confirm("Shutdown Finder Disk Analyzer and terminate its terminal process?")) return;

        const overlay = document.getElementById("loading-overlay");
        const loadingText = document.getElementById("loading-text");
        if (loadingText) loadingText.textContent = "Shutting down...";
        if (overlay) overlay.classList.add("active");

        try {
            await fetch("/api/shutdown", { method: "POST", cache: "no-store" });
        } catch (_) {}

        document.body.innerHTML = `
            <div style="height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#555;text-align:center;padding:30px;">
                <div>
                    <div style="font-size:18px;font-weight:700;color:#222;margin-bottom:8px;">Finder Disk Analyzer stopped</div>
                    <div style="font-size:13px;">The server and launcher process have been terminated. This tab can be closed.</div>
                </div>
            </div>`;
    }

    const CAT_COLORS = {
        'Folder': '#ff9500',
        'Video': '#ff3b30',
        'Audio': '#af52de',
        'Images': '#34c759',
        'Dev/Code': '#007aff',
        'Archives': '#5856d6',
        'Docs': '#5ac8fa',
        'Other': '#8e8e93'
    };

    function toggleDarkMode() {
        document.body.classList.toggle("dark-mode");
        const isDark = document.body.classList.contains("dark-mode");
        localStorage.setItem("finder_dark_mode", isDark ? "true" : "false");
        if (activeView === "sunburst") renderSunburst();
    }

    if (localStorage.getItem("finder_dark_mode") === "true") {
        document.body.classList.add("dark-mode");
    }

    function setView(view) {
        activeView = view;
        document.getElementById("btn-list").classList.toggle("active", view === "list");
        document.getElementById("btn-sunburst").classList.toggle("active", view === "sunburst");
        
        if (view === "list") {
            document.getElementById("content-list").style.display = "block";
            document.getElementById("sunburst-wrapper").style.display = "none";
        } else {
            document.getElementById("content-list").style.display = "none";
            document.getElementById("sunburst-wrapper").style.display = "block";
            renderSunburst();
        }
    }

    function showLoadingUI(message = "Scanning files & folders...") {
        document.getElementById("loading-text").textContent = message;
        document.getElementById("loading-overlay").classList.add("active");
    }

    function hideLoadingUI() {
        document.getElementById("loading-overlay").classList.remove("active");
    }

    function goHome() {
        if (homePath) loadPath(homePath);
    }

    function closePreview() {
        document.getElementById("preview-pane").classList.remove("active");
        document.getElementById("preview-media").innerHTML = "";
        selectedItem = null;
        document.querySelectorAll(".row-item").forEach(r => r.classList.remove("selected"));
    }

    async function triggerPreview(item, elem) {
        document.querySelectorAll(".row-item").forEach(r => r.classList.remove("selected"));
        if (elem) elem.classList.add("selected");
        selectedItem = item;

        const pane = document.getElementById("preview-pane");
        const media = document.getElementById("preview-media");
        const meta = document.getElementById("preview-meta");

        pane.classList.add("active");
        media.innerHTML = "";

        const fileUrl = `/api/file?path=${encodeURIComponent(item.path)}`;
        const lowerName = item.name.toLowerCase();

        if (item.category === "Images") {
            media.innerHTML = `<img src="${fileUrl}" alt="${escapeHtml(item.name)}">`;
        } else if (item.category === "Video") {
            media.innerHTML = `<video src="${fileUrl}" controls autoplay loop muted></video>`;
        } else if (lowerName.endsWith(".pdf")) {
            media.innerHTML = `<iframe src="${fileUrl}" title="${escapeHtml(item.name)}"></iframe>`;
        } else if (lowerName.endsWith(".txt") || lowerName.endsWith(".csv")) {
            media.innerHTML = '<div style="padding:18px;color:var(--text-muted);font-size:12px;">Loading preview...</div>';
            try {
                const res = await fetch(`/api/preview?path=${encodeURIComponent(item.path)}`);
                const data = await res.json();
                if (!res.ok) throw new Error(data.error || "Preview failed");

                if (data.kind === "text") {
                    media.innerHTML = `<pre class="text-preview">${escapeHtml(data.content)}${data.truncated ? "\\n\\n[Preview truncated]" : ""}</pre>`;
                } else if (data.kind === "csv") {
                    if (!data.rows.length) {
                        media.innerHTML = '<div style="padding:18px;color:var(--text-muted);font-size:12px;">CSV is empty.</div>';
                    } else {
                        const head = data.rows[0];
                        const body = data.rows.slice(1);
                        const headHtml = `<tr>${head.map(cell => `<th title="${escapeHtml(cell)}">${escapeHtml(cell)}</th>`).join("")}</tr>`;
                        const bodyHtml = body.map(row =>
                            `<tr>${row.map(cell => `<td title="${escapeHtml(cell)}">${escapeHtml(cell)}</td>`).join("")}</tr>`
                        ).join("");
                        media.innerHTML = `<div class="csv-preview-wrap"><table class="csv-preview-table"><thead>${headHtml}</thead><tbody>${bodyHtml}</tbody></table>${data.truncated ? '<div style="padding:8px;color:var(--text-muted);font-size:11px;">Preview truncated.</div>' : ""}</div>`;
                    }
                }
            } catch (err) {
                media.innerHTML = `<div style="padding:18px;color:#ff3b30;font-size:12px;">${escapeHtml(err.message)}</div>`;
            }
        } else {
            media.innerHTML = `<div style="color:var(--text-muted);font-size:13px;padding:18px;">No direct preview available for this file type.</div>`;
        }

        meta.innerHTML = `
            <div class="meta-row"><span class="meta-label">Name</span><span class="meta-value">${escapeHtml(item.name)}</span></div>
            <div class="meta-row"><span class="meta-label">Type</span><span class="meta-value">${escapeHtml(item.category)}</span></div>
            <div class="meta-row"><span class="meta-label">Size</span><span class="meta-value">${escapeHtml(item.fmt)}</span></div>
            <div class="meta-row"><span class="meta-label">Path</span><span class="meta-value">${escapeHtml(item.path)}</span></div>
        `;
    }

    async function trashItem(e, itemPath, itemName, protectedItem) {
        e.stopPropagation();
        if (protectedItem) {
            alert(`"${itemName}" is protected by macOS security policies and cannot be removed.`);
            return;
        }

        if (!confirm(`Are you sure you want to move "${itemName}" to Trash?`)) return;

        const res = await fetch('/api/trash', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: itemPath })
        });

        const data = await res.json();
        if (data.success) {
            closePreview();
            const q = document.getElementById("recursive-search").value.trim();
            if (q) {
                runRecursiveSearch(q);
            } else {
                loadPath(currentPath, true);
            }
        } else {
            alert("Failed: " + (data.message || "Check permissions."));
        }
    }

    async function loadPath(path, forceRefresh = false) {
        const requestedPath = path || currentPath || __START_PATH_JSON__;
        closePreview();
        if (!forceRefresh) {
            document.getElementById("recursive-search").value = "";
        }
        showLoadingUI("Scanning files & folders...");

        try {
            const url = '/api/scan?path=' + encodeURIComponent(requestedPath) + (forceRefresh ? '&refresh=true' : '');
            const res = await fetch(url);
            const data = await res.json();
            if (!res.ok || data.error) throw new Error(data.error || `Scan failed (${res.status})`);

            currentData = data;
            currentPath = data.current;
            homePath = data.home_path || homePath;

            const folderName = currentData.current.split("/").pop() || "Macintosh HD";
            document.getElementById("win-title").innerText = folderName;

            const d = currentData.disk;
            document.getElementById("disk-stats-text").innerText = `${d.used_fmt} used of ${d.total_fmt} (${d.pct_used}%)`;
            document.getElementById("disk-bar-fill").style.width = `${d.pct_used}%`;

            renderCategoryBar(currentData.categories, currentData.items);
            renderCrumbs();
            renderListView();

            if (activeView === "sunburst") renderSunburst();
        } catch (err) {
            document.getElementById("row-items").innerHTML =
                `<div class="loading-view"><span>${escapeHtml(err.message)}</span></div>`;
            document.getElementById("status-bar").innerText = "Scan failed";
        } finally {
            hideLoadingUI();
        }
    }

    function renderCrumbs() {
        const crumbsElem = document.getElementById("crumbs");
        crumbsElem.innerHTML = "";
        const parts = currentData.current.split("/").filter(Boolean);
        
        let accumulatedPath = "";
        const rootSpan = document.createElement("span");
        rootSpan.className = "crumb";
        rootSpan.innerText = "Macintosh HD";
        rootSpan.onclick = () => loadPath("/");
        crumbsElem.appendChild(rootSpan);

        parts.forEach((p) => {
            accumulatedPath += "/" + p;
            const thisPath = accumulatedPath;
            crumbsElem.appendChild(document.createTextNode(" > "));
            const span = document.createElement("span");
            span.className = "crumb";
            span.innerText = p;
            span.onclick = () => loadPath(thisPath);
            crumbsElem.appendChild(span);
        });
    }

    function renderCategoryBar(categories, items) {
        const totalSz = items.reduce((a, b) => a + b.size, 0) || 1;
        const bar = document.getElementById("cat-bar");
        const legend = document.getElementById("cat-legend");
        bar.innerHTML = "";
        legend.innerHTML = "";

        Object.entries(categories).forEach(([cat, sz]) => {
            const pct = (sz / totalSz) * 100;
            if (pct < 0.5) return;

            const color = CAT_COLORS[cat] || '#8e8e93';
            
            const seg = document.createElement("div");
            seg.className = "cat-seg";
            seg.style.width = `${pct}%`;
            seg.style.background = color;
            bar.appendChild(seg);

            const item = document.createElement("div");
            item.className = "legend-item";
            item.innerHTML = `<div class="legend-dot" style="background:${color}"></div> ${cat} (${pct.toFixed(1)}%)`;
            legend.appendChild(item);
        });
    }

    function renderRows(items, statusText, searchMode = false) {
        const container = document.getElementById("row-items");
        container.innerHTML = "";
        document.getElementById("status-bar").innerText = statusText;

        if (!items.length) {
            container.innerHTML = `<div class="loading-view"><span>${searchMode ? "No matching files found" : "Folder is empty"}</span></div>`;
            return;
        }

        const maxSz = Math.max(...items.map(i => i.size || 0), 1);
        const fragment = document.createDocumentFragment();

        items.forEach(item => {
            const pct = Math.max(((item.size || 0) / maxSz) * 100, 1);
            const div = document.createElement("div");
            div.className = "row-item";

            const iconSvg = item.is_dir
                ? '<svg class="file-icon" viewBox="0 0 24 24" fill="#ff9500"><path d="M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1 0 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z"/></svg>'
                : '<svg class="file-icon" viewBox="0 0 24 24" fill="#007aff"><path d="M6 2c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6H6zm7 7V3.5L18.5 9H13z"/></svg>';

            const subPath = searchMode && item.relative_path
                ? `<span class="search-subpath" title="${escapeHtml(item.relative_path)}">${escapeHtml(item.relative_path)}</span>`
                : "";

            div.innerHTML = `
                <div class="col-name" style="display:flex;align-items:center;min-width:0;">
                    ${iconSvg}
                    <span style="min-width:0;flex:1;">
                        <span style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;" title="${escapeHtml(item.name)}">${escapeHtml(item.name)}</span>
                        ${subPath}
                    </span>
                </div>
                <div class="col-bar">
                    <div class="visual-bar-bg">
                        <div class="visual-bar-fill ${item.is_dir ? "fill-dir" : "fill-file"}" style="width:${pct}%"></div>
                    </div>
                </div>
                <div class="col-size" style="font-family:monospace;font-weight:600;">${escapeHtml(item.fmt)}</div>
                <div class="col-action"></div>
            `;

            const action = div.querySelector(".col-action");
            const trashBtn = document.createElement("button");
            trashBtn.className = "btn-trash";
            trashBtn.disabled = !!item.protected;
            trashBtn.textContent = item.protected ? "Locked" : "Trash";
            if (item.protected) trashBtn.title = "System Protected Path";
            trashBtn.addEventListener("click", (e) => trashItem(e, item.path, item.name, item.protected));
            action.appendChild(trashBtn);

            div.addEventListener("click", () => {
                if (item.is_dir) {
                    loadPath(item.path);
                } else {
                    triggerPreview(item, div);
                }
            });

            fragment.appendChild(div);
        });

        container.appendChild(fragment);
    }

    function renderListView() {
        const items = currentData.items || [];
        renderRows(items, `${items.length} items in current directory`, false);
    }

    async function runRecursiveSearch(query) {
        const q = query.trim();
        if (!q) {
            renderListView();
            if (activeView === "sunburst") renderSunburst();
            return;
        }

        if (activeView !== "list") setView("list");
        closePreview();
        showLoadingUI("Searching recursively...");
        document.getElementById("status-bar").innerText = `Searching recursively in ${currentPath}...`;

        try {
            const res = await fetch(`/api/search?path=${encodeURIComponent(currentPath)}&q=${encodeURIComponent(q)}`);
            const data = await res.json();
            if (!res.ok) throw new Error(data.error || "Search failed");

            // Ignore stale results if the user changed the query while this request was running.
            if (document.getElementById("recursive-search").value.trim() !== q) return;

            const suffix = data.truncated ? ` (showing first ${data.items.length})` : "";
            renderRows(data.items, `${data.items.length} recursive match${data.items.length === 1 ? "" : "es"}${suffix}`, true);
        } catch (err) {
            document.getElementById("row-items").innerHTML =
                `<div class="loading-view"><span>${escapeHtml(err.message)}</span></div>`;
            document.getElementById("status-bar").innerText = "Search failed";
        } finally {
            hideLoadingUI();
        }
    }

    document.getElementById("recursive-search").addEventListener("input", (event) => {
        clearTimeout(searchTimer);
        const q = event.target.value.trim();

        if (!q) {
            renderListView();
            return;
        }

        searchTimer = setTimeout(() => runRecursiveSearch(q), 250);
    });

    function renderSunburst() {
        const rootName = currentData.current.split("/").pop() || "Root";
        
        const labels = [rootName];
        const parents = [""];
        const values = [currentData.items.reduce((a, b) => a + b.size, 0) || 1];
        const colors = ['#007aff'];
        const rawItems = [null];

        currentData.items.forEach(item => {
            labels.push(item.name);
            parents.push(rootName);
            values.push(item.size);
            colors.push(CAT_COLORS[item.category] || '#8e8e93');
            rawItems.push(item);
        });

        const isDark = document.body.classList.contains("dark-mode");

        const data = [{
            type: "sunburst",
            labels: labels,
            parents: parents,
            values: values,
            marker: { colors: colors },
            outsidetextfont: { size: 12, color: isDark ? "#ffffff" : "#000000" },
            leaf: { opacity: 0.8 },
            hoverinfo: "label+value",
        }];

        const layout = {
            margin: { l: 10, r: 10, b: 10, t: 10 },
            paper_bgcolor: "transparent",
            plot_bgcolor: "transparent",
            font: { color: isDark ? "#f2f2f7" : "#1c1c1e" }
        };

        Plotly.newPlot("sunburst-wrapper", data, layout, { displayModeBar: false, responsive: true });

        const myPlot = document.getElementById('sunburst-wrapper');
        myPlot.on('plotly_sunburstclick', function(data){
            const pointIndex = data.points[0].pointNumber;
            const item = rawItems[pointIndex];
            
            if (item) {
                if (item.is_dir) {
                    loadPath(item.path);
                } else {
                    triggerPreview(item, null);
                }
            }
            return false;
        });
    }

    loadPath(__START_PATH_JSON__);
</script>
</body>
</html>"""
        html = html.replace("__START_PATH_JSON__", json.dumps(START_DIR))
        html = html.replace("__HOME_PATH_JSON__", json.dumps(HOME_DIR))
        self.wfile.write(html.encode('utf-8'))

    def do_POST(self):
        if self.path == "/api/shutdown":
            try:
                temp_root = os.environ.get("FINDER_TEMP_ROOT", "")
                if temp_root and os.path.isdir(temp_root):
                    with open(os.path.join(temp_root, "shutdown-from-web"), "w", encoding="utf-8") as f:
                        f.write("1")
            except Exception:
                pass

            payload = json.dumps({"success": True, "version": APP_VERSION}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
            try:
                self.wfile.flush()
            except Exception:
                pass

            def stop_server():
                time.sleep(0.08)
                self.server.shutdown()

            threading.Thread(target=stop_server, daemon=True).start()
            return

        if self.path == "/api/trash":
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            req = json.loads(post_data.decode('utf-8'))
            
            target_path = req.get("path")
            success, msg = move_to_trash(target_path) if target_path else (False, "Invalid path")

            self.send_response(200)
            self.send_header("Content-type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps({"success": success, "message": msg}).encode('utf-8'))

class LocalThreadingTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


url = f"http://127.0.0.1:{PORT}"
print(f"Finder Disk Analyzer {APP_VERSION} running at {url}")
print(f"Initial folder: {START_DIR}")
print("Press Ctrl+C or click the red window dot to stop.")

with LocalThreadingTCPServer(("127.0.0.1", PORT), UltimateSpaceHandler) as httpd:
    webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
    finally:
        EXECUTOR.shutdown(wait=False)
PYAPP

export FINDER_START_DIR="$START_DIR"
export FINDER_TEMP_ROOT="$TMP_ROOT"

printf 'Launching analyzer...\n'
printf 'Press Ctrl+C here, or click the red window dot in the app, to stop and clean up.\n\n'

"$PYTHON" "$APP_FILE"
