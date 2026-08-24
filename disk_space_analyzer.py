cat << 'EOF' > ~/Desktop/disk_space_analyzer.py && python3 ~/Desktop/disk_space_analyzer.py
import os, sys, json, time, shutil, subprocess, webbrowser, http.server, socketserver
from concurrent.futures import ThreadPoolExecutor

PORT = 8910
EXECUTOR = ThreadPoolExecutor(max_workers=16)

SIZE_CACHE = {}
CACHE_TTL_SECONDS = 300

EXT_MAP = {
    'Video': ['.mp4', '.mov', '.mkv', '.avi', '.webm', '.m4v'],
    'Audio': ['.mp3', '.wav', '.aac', '.flac', '.m4a', '.ogg'],
    'Images': ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.heic', '.raw'],
    'Dev/Code': ['.js', '.py', '.ts', '.cpp', '.c', '.java', '.go', '.rs', '.json', '.html', '.css', '.m'],
    'Archives': ['.zip', '.tar', '.gz', '.7z', '.rar', '.dmg', '.iso'],
    'Docs': ['.pdf', '.docx', '.xlsx', '.pptx', '.txt', '.md', '.csv']
}

# Protected macOS System and Essential Directories
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
    """Checks if target path or any parent path is system-protected."""
    try:
        abs_path = os.path.realpath(os.path.abspath(target_path))
        if abs_path in PROTECTED_PATHS:
            return True
        for protected in PROTECTED_PATHS:
            if abs_path == protected:
                return True
        return False
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
    """Safely moves a file or directory to macOS Trash via AppleScript while enforcing SIP/System protection rules."""
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
    now = time.time()
    if not bypass_cache and p in SIZE_CACHE:
        cached_sz, timestamp = SIZE_CACHE[p]
        if now - timestamp < CACHE_TTL_SECONDS:
            return cached_sz

    t = 0
    try:
        with os.scandir(p) as it:
            for e in it:
                try:
                    if e.is_file(follow_symlinks=False):
                        t += e.stat(follow_symlinks=False).st_size
                    elif e.is_dir(follow_symlinks=False):
                        t += fast_dir_sz(e.path, bypass_cache)
                except Exception: pass
    except Exception: pass

    SIZE_CACHE[p] = (t, now)
    return t

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

class UltimateSpaceHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/api/scan"):
            from urllib.parse import parse_qs, urlparse
            query = parse_qs(urlparse(self.path).query)
            target = query.get("path", [os.path.expanduser("~")])[0]
            bypass_cache = query.get("refresh", ["false"])[0] == "true"
            if not target: target = os.path.expanduser("~")
            
            items, cat_breakdown = fast_parallel_scan(target, bypass_cache=bypass_cache)
            total_disk, used_disk, free_disk = shutil.disk_usage(target)

            self.send_response(200)
            self.send_header("Content-type", "application/json; charset=utf-8")
            self.end_headers()
            payload = {
                "current": target,
                "items": items[:35],
                "categories": cat_breakdown,
                "disk": {
                    "total": total_disk,
                    "used": used_disk,
                    "free": free_disk,
                    "total_fmt": fmt(total_disk),
                    "used_fmt": fmt(used_disk),
                    "free_fmt": fmt(free_disk),
                    "pct_used": round((used_disk / total_disk) * 100, 1)
                }
            }
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
    <title>Ultimate Disk Space Analyzer</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-chart-treemap@2.3.0/dist/chartjs-chart-treemap.min.js"></script>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 30px; background: #f5f5f7; color: #1d1d1f; }
        .top-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
        h2 { margin: 0; display: flex; align-items: center; gap: 10px; }
        
        .btn { display: inline-flex; align-items: center; gap: 6px; background: #007aff; color: white; border: none; padding: 10px 18px; border-radius: 8px; font-weight: 600; cursor: pointer; transition: background 0.2s, transform 0.1s; }
        .btn:hover { background: #0056b3; }
        .btn:active { transform: scale(0.97); }
        .btn-trash { background: #ff3b30; padding: 6px 12px; font-size: 12px; border-radius: 6px; margin-left: 10px; }
        .btn-trash:hover { background: #c1271d; }
        .btn-trash:disabled { background: #d1d1d6; color: #8e8e93; cursor: not-allowed; opacity: 0.6; }

        .svg-icon { width: 16px; height: 16px; fill: currentColor; display: inline-block; vertical-align: middle; }

        .card { background: white; padding: 18px; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 20px; }
        .quota-header { display: flex; justify-content: space-between; align-items: center; font-weight: 600; font-size: 14px; margin-bottom: 8px; }
        .quota-title { display: flex; align-items: center; gap: 8px; }
        .progress-bg { background: #e5e5ea; height: 16px; border-radius: 8px; overflow: hidden; }
        .progress-fill { background: linear-gradient(90deg, #34c759, #ff9500, #ff3b30); height: 100%; border-radius: 8px; }

        .cat-bar { display: flex; height: 12px; border-radius: 6px; overflow: hidden; margin-top: 10px; background: #e5e5ea; }
        .cat-seg { height: 100%; }
        .cat-legend { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 10px; font-size: 12px; font-weight: 500; }
        .cat-item { display: flex; align-items: center; gap: 6px; }
        .dot { width: 10px; height: 10px; border-radius: 50%; }

        .crumb-bar { background: white; padding: 12px 18px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); margin-bottom: 20px; font-weight: 500; font-size: 15px; }
        .crumb { color: #007aff; cursor: pointer; text-decoration: underline; }
        .crumb:hover { color: #0056b3; }
        .crumb:last-child { color: #1d1d1f; text-decoration: none; cursor: default; font-weight: 700; }

        .view-controls { display: flex; gap: 10px; margin-bottom: 20px; }
        .toggle-btn { display: inline-flex; align-items: center; gap: 8px; background: #e5e5ea; color: #1d1d1f; border: none; padding: 8px 16px; border-radius: 8px; font-weight: 600; cursor: pointer; }
        .toggle-btn.active { background: #007aff; color: white; }

        .item { display: flex; align-items: center; margin-bottom: 10px; background: white; padding: 14px 18px; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); cursor: pointer; transition: transform 0.1s ease; }
        .item:hover { transform: translateY(-2px); box-shadow: 0 4px 8px rgba(0,0,0,0.12); }
        .label { width: 220px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .bar-container { flex-grow: 1; background: #e5e5ea; height: 18px; border-radius: 9px; overflow: hidden; margin: 0 15px; }
        .bar { height: 100%; border-radius: 9px; }
        .dir { background: #ff3b30; }
        .file { background: #007aff; }
        .size { width: 90px; text-align: right; font-weight: 600; font-family: monospace; }
        .badge { font-size: 11px; padding: 3px 8px; border-radius: 4px; color: white; margin-right: 12px; font-weight: bold; width: 35px; text-align: center; }
        .badge-dir { background: #ff9500; }
        .badge-file { background: #34c759; }
        .badge-protected { background: #8e8e93; }

        #treemap-wrapper { display: none; background: white; padding: 20px; border-radius: 12px; box-shadow: 0 2px 6px rgba(0,0,0,0.05); height: 500px; }

        .loading-container { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 60px 20px; background: white; border-radius: 12px; box-shadow: 0 2px 6px rgba(0,0,0,0.05); }
        .spinner-outer { position: relative; width: 64px; height: 64px; display: flex; align-items: center; justify-content: center; margin-bottom: 18px; }
        .spinner-ring { position: absolute; width: 100%; height: 100%; border-radius: 50%; border: 4px solid #e5e5ea; border-top-color: #007aff; animation: spin 0.8s cubic-bezier(0.68, -0.55, 0.265, 1.55) infinite; }
        .spinner-pulse { width: 28px; height: 28px; background: #007aff; border-radius: 50%; animation: pulse 1.2s ease-in-out infinite; opacity: 0.7; }
        @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
        @keyframes pulse { 0% { transform: scale(0.6); opacity: 0.3; } 50% { transform: scale(1.1); opacity: 0.9; } 100% { transform: scale(0.6); opacity: 0.3; } }
        .loading-title { font-size: 17px; font-weight: 700; color: #1d1d1f; margin-bottom: 6px; }
        .loading-sub { font-size: 13px; color: #86868b; font-family: monospace; }
    </style>
</head>
<body>
    <div class="top-row">
        <h2>Ultimate Disk Analyzer</h2>
        <button class="btn" onclick="loadPath(currentPath, true)">
            <svg class="svg-icon" viewBox="0 0 24 24"><path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/></svg>
            Rescan Folder
        </button>
    </div>

    <div class="card" id="quota-card">
        <div class="quota-header">
            <span class="quota-title">
                <svg class="svg-icon" viewBox="0 0 24 24"><path d="M20 6H4c-1.1 0-1.99.9-1.99 2L2 16c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-5 10H4v-3h11v3zm0-5H4V8h11v3zm5 5h-3V8h3v8z"/></svg>
                SSD Volume Usage
            </span>
            <span id="quota-text">...</span>
        </div>
        <div class="progress-bg">
            <div class="progress-fill" id="quota-bar" style="width: 0%"></div>
        </div>
        <div class="cat-bar" id="cat-bar"></div>
        <div class="cat-legend" id="cat-legend"></div>
    </div>

    <div class="crumb-bar" id="crumbs">Loading...</div>

    <div class="view-controls">
        <button class="toggle-btn active" id="btn-list" onclick="setView('list')">
            <svg class="svg-icon" viewBox="0 0 24 24"><path d="M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z"/></svg>
            List View
        </button>
        <button class="toggle-btn" id="btn-tree" onclick="setView('tree')">
            <svg class="svg-icon" viewBox="0 0 24 24"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM9 17H7v-7h2v7zm4 0h-2V7h2v10zm4 0h-2v-4h2v4z"/></svg>
            Treemap View
        </button>
    </div>

    <div id="content"></div>
    <div id="treemap-wrapper">
        <canvas id="treemapCanvas"></canvas>
    </div>

    <script>
        let currentPath = "";
        let timerInterval = null;
        let currentData = null;
        let treemapChart = null;
        let activeView = "list";

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

        function setView(view) {
            activeView = view;
            document.getElementById("btn-list").classList.toggle("active", view === "list");
            document.getElementById("btn-tree").classList.toggle("active", view === "tree");
            
            if (view === "list") {
                document.getElementById("content").style.display = "block";
                document.getElementById("treemap-wrapper").style.display = "none";
            } else {
                document.getElementById("content").style.display = "none";
                document.getElementById("treemap-wrapper").style.display = "block";
                renderTreemap();
            }
        }

        function showLoadingUI() {
            const content = document.getElementById("content");
            content.innerHTML = `
                <div class="loading-container">
                    <div class="spinner-outer">
                        <div class="spinner-ring"></div>
                        <div class="spinner-pulse"></div>
                    </div>
                    <div class="loading-title">Scanning Directory Parallel Threads...</div>
                    <div class="loading-sub" id="timer-text">Elapsed: 0.0s</div>
                </div>
            `;

            if (timerInterval) clearInterval(timerInterval);
            const startTime = Date.now();
            timerInterval = setInterval(() => {
                const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
                const timerElem = document.getElementById("timer-text");
                if (timerElem) timerElem.innerText = `Elapsed: ${elapsed}s`;
            }, 100);
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
                loadPath(currentPath, true);
            } else {
                alert("Failed: " + (data.message || "Check permissions."));
            }
        }

        async function loadPath(path, forceRefresh = false) {
            currentPath = path;
            showLoadingUI();
            
            const url = '/api/scan?path=' + encodeURIComponent(path) + (forceRefresh ? '&refresh=true' : '');
            const res = await fetch(url);
            currentData = await res.json();
            
            if (timerInterval) clearInterval(timerInterval);

            const d = currentData.disk;
            document.getElementById("quota-text").innerText = `${d.used_fmt} used of ${d.total_fmt} (${d.pct_used}%)`;
            document.getElementById("quota-bar").style.width = `${d.pct_used}%`;

            renderCategoryBar(currentData.categories, currentData.items);

            const crumbsElem = document.getElementById("crumbs");
            crumbsElem.innerHTML = "";
            const parts = currentData.current.split("/").filter(Boolean);
            
            let accumulatedPath = "";
            const rootSpan = document.createElement("span");
            rootSpan.className = "crumb";
            rootSpan.innerText = "/";
            rootSpan.onclick = () => loadPath("/");
            crumbsElem.appendChild(rootSpan);

            parts.forEach((p) => {
                accumulatedPath += "/" + p;
                const thisPath = accumulatedPath;
                crumbsElem.appendChild(document.createTextNode(" / "));
                const span = document.createElement("span");
                span.className = "crumb";
                span.innerText = p;
                span.onclick = () => loadPath(thisPath);
                crumbsElem.appendChild(span);
            });

            renderListView();
            if (activeView === "tree") renderTreemap();
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
                item.className = "cat-item";
                item.innerHTML = `<div class="dot" style="background:${color}"></div> ${cat} (${pct.toFixed(1)}%)`;
                legend.appendChild(item);
            });
        }

        function renderListView() {
            const container = document.getElementById("content");
            container.innerHTML = "";

            if (!currentData.items || currentData.items.length === 0) {
                container.innerHTML = '<div class="loading-container"><div class="loading-title" style="color:#86868b">No accessible items in this folder.</div></div>';
                return;
            }

            const maxSz = currentData.items[0].size || 1;

            currentData.items.forEach(item => {
                const pct = Math.max((item.size / maxSz) * 100, 1);
                const div = document.createElement("div");
                div.className = "item";
                
                const protectedAttr = item.protected ? 'disabled title="Protected macOS path"' : '';

                div.innerHTML = `
                    <span class="badge ${item.protected ? 'badge-protected' : (item.is_dir ? 'badge-dir' : 'badge-file')}">${item.protected ? 'PROT' : (item.is_dir ? 'DIR' : 'FILE')}</span>
                    <span class="label" title="${item.name}">${item.name}</span>
                    <div class="bar-container">
                        <div class="bar ${item.is_dir ? 'dir' : 'file'}" style="width: ${pct}%"></div>
                    </div>
                    <span class="size">${item.fmt}</span>
                    <button class="btn btn-trash" ${protectedAttr} onclick="trashItem(event, '${item.path.replace(/'/g, "\\'")}', '${item.name.replace(/'/g, "\\'")}', ${item.protected})">
                        <svg class="svg-icon" viewBox="0 0 24 24"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>
                        ${item.protected ? 'Protected' : 'Trash'}
                    </button>
                `;

                if (item.is_dir) {
                    div.onclick = () => loadPath(item.path);
                }
                container.appendChild(div);
            });
        }

        function renderTreemap() {
            if (treemapChart) treemapChart.destroy();
            const ctx = document.getElementById("treemapCanvas").getContext("2d");

            const treeData = currentData.items.slice(0, 20).map(i => ({
                name: i.name,
                value: i.size,
                fmt: i.fmt,
                category: i.category,
                is_dir: i.is_dir,
                path: i.path
            }));

            treemapChart = new Chart(ctx, {
                type: 'treemap',
                data: {
                    datasets: [{
                        tree: treeData,
                        key: 'value',
                        groups: ['name'],
                        backgroundColor: (ctx) => {
                            const item = ctx.raw?._data;
                            return item ? (CAT_COLORS[item.category] || '#8e8e93') : '#ccc';
                        },
                        labels: {
                            display: true,
                            formatter: (ctx) => [ctx.raw._data.name, ctx.raw._data.fmt],
                            color: '#white',
                            font: { weight: 'bold', size: 12 }
                        }
                    }]
                },
                options: {
                    plugins: { legend: { display: false } },
                    maintainAspectRatio: false,
                    onClick: (e, active) => {
                        if (active.length > 0) {
                            const raw = active[0].element.$context.raw._data;
                            if (raw && raw.is_dir) loadPath(raw.path);
                        }
                    }
                }
            });
        }

        loadPath("");
    </script>
</body>
</html>"""
        self.wfile.write(html.encode('utf-8'))

    def do_POST(self):
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

print(f"Ultimate Disk Analyzer running at http://localhost:{PORT}")
webbrowser.open(f"http://localhost:{PORT}")
with socketserver.TCPServer(("", PORT), UltimateSpaceHandler) as httpd:
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")
EOF
