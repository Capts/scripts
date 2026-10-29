#!/usr/bin/env python3
"""
DriveDoctor - macOS HDD/SSD diagnostic & repair tool
(desktop drives and 24/7 surveillance drives)

Run:  python3 drivedoctor.py        (it re-launches itself with sudo)

Optional but recommended:  brew install smartmontools gptfdisk
The tool offers to install them for you.
"""
import os
import re
import sys
import time
import fcntl
import shutil
import plistlib
import subprocess

if sys.platform != "darwin":
    sys.exit("DriveDoctor only runs on macOS.")
if os.geteuid() != 0:
    os.execvp("sudo", ["sudo", sys.executable] + sys.argv)

REAL_USER = os.environ.get("SUDO_USER") or "root"
os.environ["PATH"] += ":/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin"

MB = 1024 * 1024
F_NOCACHE = getattr(fcntl, "F_NOCACHE", 48)
F_FULLFSYNC = getattr(fcntl, "F_FULLFSYNC", 51)
SLOW_SECS = 1.0  # a single 8 MB read slower than this is flagged as a weak area


class C:
    G, R, Y, B, C, X, BOLD = "\033[92m", "\033[91m", "\033[93m", "\033[94m", "\033[96m", "\033[0m", "\033[1m"


def ok(m): print(f"{C.G}[+] {m}{C.X}")
def bad(m): print(f"{C.R}[!] {m}{C.X}")
def warn(m): print(f"{C.Y}[~] {m}{C.X}")
def info(m): print(f"{C.C}[i] {m}{C.X}")


def run(cmd):
    return subprocess.run(cmd, text=True, capture_output=True)


def plist(cmd):
    try:
        return plistlib.loads(subprocess.run(cmd, capture_output=True).stdout)
    except Exception:
        return {}


def ask(prompt):
    try:
        return input(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return ""


def hsize(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000 or u == "TB":
            return f"{n:.1f} {u}" if u != "B" else f"{n} B"
        n /= 1000.0


def hdur(s):
    s = int(s)
    return f"{s // 3600}h {s % 3600 // 60}m" if s >= 3600 else f"{s // 60}m {s % 60}s"


def confirm_destructive(disk, what):
    d = next((x for x in list_disks() if x["id"] == disk), None)
    label = f"{d['name']} ({hsize(d['size'])})" if d else disk
    print(f"\n{C.R}{C.BOLD}DESTRUCTIVE: {what}{C.X}")
    print(f"{C.R}Target: /dev/{disk}  {label}{C.X}")
    return ask(f"Type the disk id ({disk}) to confirm, anything else cancels: ") == disk


# ----------------------------------------------------------------- disks ----
def disk_info(ident):
    return plist(["diskutil", "info", "-plist", ident])


def boot_disks():
    boots = set()
    parent = disk_info("/").get("ParentWholeDisk")
    if parent:
        boots.add(parent)
        for s in disk_info(parent).get("APFSPhysicalStores", []):
            m = re.match(r"disk\d+", s.get("APFSPhysicalStore", ""))
            if m:
                boots.add(m.group())
    return boots


def list_disks():
    boots, out = boot_disks(), []
    for d in plist(["diskutil", "list", "-plist", "physical"]).get("WholeDisks", []):
        i = disk_info(d)
        out.append(dict(id=d, size=i.get("TotalSize", 0), name=i.get("MediaName") or "Unknown",
                        internal=i.get("Internal", False), ssd=i.get("SolidState", False),
                        bus=i.get("BusProtocol", "?"), smart=i.get("SMARTStatus", "n/a"),
                        boot=d in boots))
    return out


def pick_disk(prompt="Select disk", allow_boot=False, exclude=None):
    disks = [d for d in list_disks() if d["id"] != exclude]
    if not disks:
        bad("No physical disks found.")
        return None
    print(f"\n{C.BOLD}{'#':<3} {'Disk':<8} {'Size':<10} {'Type':<5} {'Bus':<9} {'SMART':<12} Name{C.X}")
    for n, d in enumerate(disks, 1):
        kind = "SSD" if d["ssd"] else "HDD"
        tag = f"  {C.R}<- SYSTEM DISK{C.X}" if d["boot"] else ("  (internal)" if d["internal"] else "")
        print(f"{n:<3} {d['id']:<8} {hsize(d['size']):<10} {kind:<5} {d['bus']:<9} {d['smart']:<12} {d['name']}{tag}")
    v = ask(f"{prompt} (number, blank to cancel): ")
    if not v.isdigit() or not (1 <= int(v) <= len(disks)):
        return None
    d = disks[int(v) - 1]
    if d["boot"] and not allow_boot:
        bad("That is the macOS system disk. Refusing for safety.")
        return None
    return d["id"]


def volumes(disk):
    vols = []
    for e in plist(["diskutil", "list", "-plist", disk]).get("AllDisksAndPartitions", []):
        for p in e.get("Partitions", []) + e.get("APFSVolumes", []):
            if p.get("Content") in ("EFI", "Apple_APFS_ISC"):
                continue
            i = disk_info(p["DeviceIdentifier"])
            vols.append(dict(id=p["DeviceIdentifier"], fs=i.get("FilesystemType", ""),
                             name=i.get("VolumeName", ""), mount=i.get("MountPoint", ""),
                             writable=i.get("WritableVolume", False)))
    return vols


# ------------------------------------------------------------- tool setup ----
def ensure_tool(binary, pkg):
    path = shutil.which(binary)
    if path:
        return path
    brew = shutil.which("brew")
    if not brew:
        warn(f"{binary} missing and Homebrew not installed (https://brew.sh).")
        return None
    if ask(f"{binary} is not installed. Install '{pkg}' with Homebrew? [Y/n]: ").lower() in ("", "y", "yes"):
        if REAL_USER == "root":
            bad("Homebrew refuses to run as root; run this tool via sudo from your normal user.")
            return None
        subprocess.run(["sudo", "-u", REAL_USER, brew, "install", pkg])
        return shutil.which(binary)
    return None


# ------------------------------------------------------------------ SMART ----
CRIT = {5: "Reallocated sectors", 187: "Reported uncorrectable", 196: "Reallocation events",
        197: "Pending (unreadable) sectors", 198: "Offline uncorrectable"}
INFO = {9: "Power-on hours", 194: "Temperature (C)", 188: "Command timeouts",
        199: "UDMA CRC errors (cable/enclosure)"}


def smart_read(disk):
    sc = ensure_tool("smartctl", "smartmontools")
    if not sc:
        return None
    txt = ""
    for extra in ([], ["-d", "sat"]):  # many USB enclosures need SAT passthrough
        txt = run([sc, "-a"] + extra + [f"/dev/{disk}"]).stdout
        if "ID# ATTRIBUTE_NAME" in txt or "NVMe" in txt:
            break
    s = dict(text=txt, attrs={}, health=None, nvme="NVMe" in txt)
    m = re.search(r"(?:overall-health[^:]*|SMART Health Status):\s*(\w+)", txt)
    s["health"] = m.group(1) if m else None
    s["model"] = (re.search(r"(?:Device Model|Model Number|Product):\s*(.+)", txt) or [None, "?"])[1].strip()
    in_tbl = False
    for line in txt.splitlines():
        if "ID# ATTRIBUTE_NAME" in line:
            in_tbl = True
            continue
        f = line.split()
        if in_tbl and len(f) >= 10 and f[0].isdigit():
            m = re.match(r"\d+", f[9])
            s["attrs"][int(f[0])] = (f[1], int(m.group()) if m else 0)
    return s


def smart_assess(s):
    """Returns list of (level, message); level is 'bad' or 'warn'."""
    res = []
    if s["health"] and s["health"].upper() not in ("PASSED", "OK"):
        res.append(("bad", f"SMART overall health: {s['health']}  -> drive is failing, back up now"))
    a = s["attrs"]
    for i in (5, 196, 197, 198, 187):
        if i in a and a[i][1] > 0:
            lvl = "bad" if i in (197, 198) or a[i][1] > 50 else "warn"
            res.append((lvl, f"{CRIT[i]} = {a[i][1]}"))
    if 199 in a and a[199][1] > 0:
        res.append(("warn", f"UDMA CRC errors = {a[199][1]}  -> try another cable/port/enclosure"))
    if 194 in a and a[194][1] >= 55:
        res.append(("warn", f"Temperature {a[194][1]}C is high; improve airflow (common in DVR/NVR boxes)"))
    if s["nvme"]:
        m = re.search(r"Critical Warning:\s*(0x[0-9a-fA-F]+)", s["text"])
        if m and int(m.group(1), 16):
            res.append(("bad", f"NVMe critical warning {m.group(1)}"))
        m = re.search(r"Media and Data Integrity Errors:\s*(\d+)", s["text"])
        if m and int(m.group(1)):
            res.append(("bad", f"NVMe media errors = {m.group(1)}"))
        m = re.search(r"Percentage Used:\s*(\d+)", s["text"])
        if m and int(m.group(1)) >= 90:
            res.append(("warn", f"NVMe wear {m.group(1)}% used"))
    return res


def smart_report(disk):
    s = smart_read(disk)
    if not s:
        d = disk_info(disk)
        warn(f"smartctl unavailable. macOS says SMART status: {d.get('SMARTStatus', 'n/a')}")
        return None
    if not s["attrs"] and not s["nvme"]:
        warn("No SMART data. Many USB enclosures/docks hide SMART; connect the drive via SATA directly if possible.")
        return s
    print(f"\n{C.BOLD}Model:{C.X} {s['model']}   {C.BOLD}Health:{C.X} {s['health']}")
    for table in (CRIT, INFO):
        for i, label in table.items():
            if i in s["attrs"]:
                v = s["attrs"][i][1]
                col = C.R if (table is CRIT and v > 0) else C.X
                print(f"  {col}{i:>3}  {label:<38} {v}{C.X}")
    issues = smart_assess(s)
    if not issues:
        ok("No SMART warning signs.")
    for lvl, m in issues:
        (bad if lvl == "bad" else warn)(m)
    return s


def smart_selftest(disk):
    sc = ensure_tool("smartctl", "smartmontools")
    if not sc:
        return
    kind = ask("Self-test: [s]hort (~2 min, waits) or [l]ong (hours, runs in drive)? [s/l]: ").lower()
    extra = [] if "NVMe" in run([sc, "-i", f"/dev/{disk}"]).stdout else []
    if "ID# ATTRIBUTE_NAME" not in run([sc, "-a", f"/dev/{disk}"]).stdout:
        extra = ["-d", "sat"]
    r = run([sc, "-t", "long" if kind == "l" else "short"] + extra + [f"/dev/{disk}"])
    print(r.stdout[-600:])
    if kind == "l":
        info("Long test started. Keep the drive powered and awake; check later via option 2 -> log.")
        return
    info("Waiting for short test (Ctrl+C to stop waiting)...")
    try:
        for _ in range(60):
            time.sleep(10)
            t = run([sc, "-a"] + extra + [f"/dev/{disk}"]).stdout
            if "in progress" not in t.lower():
                break
    except KeyboardInterrupt:
        pass
    print(run([sc, "-l", "selftest"] + extra + [f"/dev/{disk}"]).stdout[-900:])


# ----------------------------------------------------------- surface scan ----
def surface_scan(disk, size, chunk=8 * MB):
    """Read-only full-surface read. Finds unreadable and abnormally slow regions."""
    fd = os.open(f"/dev/r{disk}", os.O_RDONLY)
    fcntl.fcntl(fd, F_NOCACHE, 1)
    bad_regions, slow, off, t0, slowest = [], 0, 0, time.time(), 1e9
    info(f"Scanning {hsize(size)} read-only. Ctrl+C stops and shows results.")
    try:
        while off < size:
            n = min(chunk, size - off)
            t = time.time()
            try:
                os.pread(fd, n, off)
            except OSError:
                for sub in range(off, off + n, 64 * 1024):  # isolate the bad spot
                    try:
                        os.pread(fd, min(64 * 1024, off + n - sub), sub)
                    except OSError:
                        bad_regions.append(sub)
            dt = time.time() - t
            if dt > SLOW_SECS:
                slow += 1
            if dt > 0:
                slowest = min(slowest, n / dt / MB)
            off += n
            el = time.time() - t0
            if int(el * 4) % 4 == 0 or off >= size:
                spd = off / max(el, 0.001) / MB
                eta = (size - off) / (off / max(el, 0.001))
                print(f"\r  {off * 100 // size:>3}%  {spd:6.0f} MB/s  bad:{len(bad_regions):<4} slow:{slow:<4} ETA {hdur(eta)}   ",
                      end="", flush=True)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        os.close(fd)
    el = max(time.time() - t0, 0.001)
    print()
    res = dict(bad=len(bad_regions), slow=slow, avg=off / el / MB, scanned=off)
    print(f"Scanned {hsize(off)} in {hdur(el)}, avg {res['avg']:.0f} MB/s, slowest chunk {slowest:.1f} MB/s")
    if bad_regions:
        bad(f"{len(bad_regions)} unreadable 64KB block(s). First at byte {bad_regions[0]}. "
            "Clone data off, then use the refresh/burn-in option.")
    elif slow:
        warn(f"{slow} slow area(s) (>{SLOW_SECS}s per 8MB): weak sectors the drive is struggling to read.")
    else:
        ok("Entire surface read cleanly.")
    return res


# -------------------------------------------------------------- benchmark ----
def benchmark(mount, size_mb=1024):
    if shutil.disk_usage(mount).free < size_mb * MB * 1.2:
        warn("Not enough free space for a 1GB test.")
        return
    path = os.path.join(mount, ".drivedoctor_bench.tmp")
    block = os.urandom(8 * MB)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        fcntl.fcntl(fd, F_NOCACHE, 1)
        t = time.time()
        for _ in range(size_mb // 8):
            os.write(fd, block)
        fcntl.fcntl(fd, F_FULLFSYNC)
        w = size_mb / (time.time() - t)
        os.close(fd)
        fd = os.open(path, os.O_RDONLY)
        fcntl.fcntl(fd, F_NOCACHE, 1)
        t = time.time()
        while os.read(fd, 8 * MB):
            pass
        r = size_mb / (time.time() - t)
        os.close(fd)
        print(f"  Write: {w:.0f} MB/s    Read: {r:.0f} MB/s   ({mount})")
        if min(w, r) < 40:
            warn("Very slow for a modern drive: check cable/port, USB2 vs USB3, or failing disk.")
    except OSError as e:
        bad(f"Benchmark failed: {e}")
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


# --------------------------------------------------------------- repairs ----
FSCK = {"exfat": ["fsck_exfat", "-y"], "msdos": ["fsck_msdos", "-y"],
        "hfs": ["fsck_hfs", "-fy"], "apfs": ["fsck_apfs", "-y"]}


def repair(disk):
    print(f"\n{C.BOLD}Step 1: partition map{C.X}")
    r = subprocess.run(["diskutil", "repairDisk", disk])
    if r.returncode != 0:
        warn("Partition map repair reported a problem (see above).")
    vols = volumes(disk)
    if not vols:
        warn("No volumes found. If this is a DVR/NVR/Linux disk (ext4/proprietary), macOS can't repair it:\n"
             "    - repair it inside the DVR, or on Linux with 'fsck.ext4 -f /dev/sdX1'.")
        return
    for v in vols:
        print(f"\n{C.BOLD}Step 2: {v['id']} ({v['fs'] or 'unknown'}) {v['name']}{C.X}")
        if v["fs"] == "ntfs":
            warn("NTFS: macOS cannot repair it. Use Windows: chkdsk X: /f")
            continue
        if subprocess.run(["diskutil", "verifyVolume", v["id"]]).returncode == 0:
            ok("Volume is healthy.")
            continue
        warn("Problems found, attempting repair...")
        if subprocess.run(["diskutil", "repairVolume", v["id"]]).returncode == 0:
            ok("Repaired.")
            continue
        tool = FSCK.get(v["fs"])
        if tool:
            warn(f"Trying low-level {tool[0]}...")
            subprocess.run(["diskutil", "unmountDisk", "force", disk])
            if subprocess.run(tool + [f"/dev/r{v['id']}"]).returncode == 0:
                ok("Low-level repair succeeded. Re-mount with: diskutil mountDisk " + disk)
                continue
        bad("Could not repair. Rescue files first (option 6), then erase/refresh the disk.")


def rescue(disk):
    c = ask("[m] mount read-only to copy files, or [c] clone to another disk? [m/c]: ").lower()
    if c == "m":
        subprocess.run(["diskutil", "unmountDisk", "force", disk])
        subprocess.run(["diskutil", "mountDisk", "readOnly", disk])
        info("Mounted read-only. Copy your files off with Finder or: rsync -a /Volumes/NAME/ ~/Rescue/")
    elif c == "c":
        clone(disk)


def clone(src):
    dst = pick_disk("Select DESTINATION disk (will be ERASED)", exclude=src)
    if not dst:
        return
    s, d = disk_info(src).get("TotalSize", 0), disk_info(dst).get("TotalSize", 0)
    if d < s:
        bad(f"Destination ({hsize(d)}) is smaller than source ({hsize(s)}). A raw clone would truncate the last "
            "partition and the system will not boot. Use a same-size/larger disk, or a file-level copy.")
        return
    if not confirm_destructive(dst, f"clone /dev/{src} -> /dev/{dst}, overwriting everything on {dst}"):
        print("Cancelled.")
        return
    for x in (src, dst):
        subprocess.run(["diskutil", "unmountDisk", "force", x], capture_output=True)
    fs = os.open(f"/dev/r{src}", os.O_RDONLY)
    fd = os.open(f"/dev/r{dst}", os.O_WRONLY)
    fcntl.fcntl(fs, F_NOCACHE, 1)
    fcntl.fcntl(fd, F_NOCACHE, 1)
    off, bad_blocks, t0, chunk = 0, [], time.time(), 4 * MB
    try:
        while off < s:
            n = min(chunk, s - off)
            try:
                data = os.pread(fs, n, off)
            except OSError:  # unreadable area: zero-fill so offsets stay aligned, and log it
                data = b""
                for sub in range(off, off + n, 64 * 1024):
                    m = min(64 * 1024, off + n - sub)
                    try:
                        data += os.pread(fs, m, sub)
                    except OSError:
                        bad_blocks.append(sub)
                        data += b"\0" * m
            os.pwrite(fd, data, off)
            off += n
            el = max(time.time() - t0, 0.001)
            print(f"\r  {off * 100 // s:>3}%  {off / el / MB:6.0f} MB/s  unreadable blocks: {len(bad_blocks)}  "
                  f"ETA {hdur((s - off) / (off / el))}   ", end="", flush=True)
    except KeyboardInterrupt:
        print("\nInterrupted: destination is incomplete.")
        return
    finally:
        os.close(fs)
        os.close(fd)
    print()
    ok(f"Copied {hsize(off)}.")
    if bad_blocks:
        warn(f"{len(bad_blocks)} unreadable 64KB block(s) were zero-filled (first at byte {bad_blocks[0]}).")
    if d > s:
        sg = ensure_tool("sgdisk", "gptfdisk")
        if sg:
            subprocess.run([sg, "-e", f"/dev/{dst}"])
            ok("Backup GPT moved to the end of the larger disk.")
    subprocess.run(["diskutil", "list", dst])


def refresh_and_burn_in(disk):
    """Overwrite whole disk with zeros so the firmware remaps weak sectors, then re-read and re-check SMART."""
    size = disk_info(disk).get("TotalSize", 0)
    print(f"\n{C.BOLD}Refresh + burn-in{C.X}\nThis fixes 'pending sector' problems (SMART 197/198) by forcing the drive to "
          "rewrite or remap them.\nIt cannot repair a physically dying head/motor. Estimated time: "
          f"{hdur(size / (120 * MB))} write + {hdur(size / (120 * MB))} verify.")
    before = smart_report(disk)
    if not confirm_destructive(disk, "ERASE ALL DATA, then full write + read test"):
        print("Cancelled.")
        return
    t = time.time()
    if subprocess.run(["diskutil", "zeroDisk", disk]).returncode != 0:
        bad("zeroDisk failed (disk busy, locked, or write-protected enclosure).")
        return
    ok(f"Zero-write finished in {hdur(time.time() - t)}.")
    res = surface_scan(disk, size)
    print(f"\n{C.BOLD}After burn-in:{C.X}")
    after = smart_report(disk)
    verdict = "PASS"
    if res["bad"] or (after and any(l == "bad" for l, _ in smart_assess(after))):
        verdict = "FAIL"
    elif res["slow"] or (after and smart_assess(after)):
        verdict = "WARN"
    if before and after:
        for i in (5, 197, 198):
            if i in before["attrs"] and i in after["attrs"]:
                print(f"  {CRIT[i]:<32} before {before['attrs'][i][1]:<6} after {after['attrs'][i][1]}")
        if 5 in before["attrs"] and after["attrs"].get(5, (0, 0))[1] > before["attrs"][5][1] + 20:
            verdict = "FAIL"
            bad("Reallocated sector count is climbing fast: the platters are degrading.")
    {"PASS": ok, "WARN": warn, "FAIL": bad}[verdict](
        {"PASS": "PASS: drive is reusable. Reformat it (option 8). Re-test again in a few weeks.",
         "WARN": "WARN: usable for non-critical data only (not evidence/surveillance footage).",
         "FAIL": "FAIL: replace this drive. Do not use it for important or surveillance data."}[verdict])


def erase_reformat(disk):
    print("Formats: [1] ExFAT (Mac+Windows)  [2] APFS (Mac only)  [3] Mac OS Extended (HDD, Time Machine)  [4] FAT32 (<=32GB)")
    fmt = {"1": "ExFAT", "2": "APFS", "3": "JHFS+", "4": "MS-DOS FAT32"}.get(ask("Choose: "))
    if not fmt:
        return
    name = re.sub(r"[^\w .-]", "", ask("Volume name [Untitled]: ") or "Untitled")[:11] or "Untitled"
    warn("NVR/DVR note: recorders normally want to format the disk themselves. Format it in the recorder instead.")
    if confirm_destructive(disk, f"erase and format as {fmt}"):
        subprocess.run(["diskutil", "eraseDisk", fmt, name, "GPT", disk])


def full_checkup(disk):
    print(f"\n{C.BOLD}=== 1/4 SMART health ==={C.X}")
    s = smart_report(disk)
    print(f"\n{C.BOLD}=== 2/4 Partition map ==={C.X}")
    pm = subprocess.run(["diskutil", "verifyDisk", disk]).returncode == 0
    print(f"\n{C.BOLD}=== 3/4 File systems (read-only verify) ==={C.X}")
    fs_bad = []
    first_mount = None
    for v in volumes(disk):
        if v["fs"] in ("ntfs", ""):
            info(f"{v['id']}: {v['fs'] or 'unknown'} filesystem, cannot verify on macOS.")
            continue
        if subprocess.run(["diskutil", "verifyVolume", v["id"]], capture_output=True).returncode == 0:
            ok(f"{v['id']} {v['name']}: healthy")
        else:
            bad(f"{v['id']} {v['name']}: needs repair")
            fs_bad.append(v["id"])
        if v["mount"] and v["writable"] and not first_mount:
            first_mount = v["mount"]
    print(f"\n{C.BOLD}=== 4/4 Speed ==={C.X}")
    if first_mount:
        benchmark(first_mount)
    else:
        info("No writable mounted volume to benchmark.")
    print(f"\n{C.BOLD}=== Summary & recommended next step ==={C.X}")
    issues = smart_assess(s) if s else []
    if any(l == "bad" for l, _ in issues):
        bad("Drive is failing. Next: option 6 (clone/rescue), then replace the drive.")
    elif issues:
        warn("Warning signs present. Next: option 3 (surface scan); if pending sectors > 0, back up and run option 7.")
    elif not pm or fs_bad:
        warn("Software damage only. Next: option 5 (repair). Hardware looks fine.")
    else:
        ok("Everything looks healthy. Optional deeper check: option 3 (surface scan).")


# ------------------------------------------------------------------ menu ----
def main():
    subprocess.Popen(["caffeinate", "-dimsu", "-w", str(os.getpid())])  # no sleep during long jobs
    print(f"{C.B}{C.BOLD}\n  DriveDoctor - macOS drive diagnostic & repair{C.X}")
    disk = pick_disk("Select the drive to work on")
    while True:
        cur = disk or "none"
        print(f"\n{C.B}============ Current disk: {cur} ============{C.X}")
        print("  [1] Full check-up           (safe, read-only)")
        print("  [2] SMART health / self-test (safe)")
        print("  [3] Surface scan            (safe, find bad/slow sectors)")
        print("  [4] Speed test              (safe, 1GB temp file)")
        print("  [5] Repair partition map & file system")
        print("  [6] Rescue: read-only mount / clone to another disk")
        print(f"  {C.Y}[7] Refresh bad sectors + burn-in  (ERASES disk){C.X}")
        print(f"  {C.Y}[8] Erase & reformat                (ERASES disk){C.X}")
        print("  [d] Change disk    [q] Quit")
        c = ask("> ").lower()
        if c == "q":
            return
        if c == "d":
            disk = pick_disk("Select the drive to work on") or disk
            continue
        if c not in list("12345678"):
            continue
        if not disk:
            disk = pick_disk("Select the drive to work on")
            if not disk:
                continue
        try:
            if c == "1":
                full_checkup(disk)
            elif c == "2":
                smart_report(disk)
                if ask("Run a SMART self-test? [y/N]: ").lower() == "y":
                    smart_selftest(disk)
            elif c == "3":
                surface_scan(disk, disk_info(disk).get("TotalSize", 0))
            elif c == "4":
                mounted = [v for v in volumes(disk) if v["mount"] and v["writable"]]
                if mounted:
                    benchmark(mounted[0]["mount"])
                else:
                    warn("No writable mounted volume on this disk.")
            elif c == "5":
                repair(disk)
            elif c == "6":
                rescue(disk)
            elif c == "7":
                refresh_and_burn_in(disk)
            elif c == "8":
                erase_reformat(disk)
        except KeyboardInterrupt:
            print("\nCancelled.")
        ask("\nPress Enter to return to the menu...")


if __name__ == "__main__":
    main()
