import argparse, json, time, os, ctypes, sys
from datetime import datetime
import ctypes.wintypes as wt
import numpy as np
import mss, cv2
from PIL import Image

# =========================
#  Process & console setup
# =========================
try:
    ctypes.windll.user32.SetProcessDPIAware()
except Exception:
    pass

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def _safe_print(*objs, **kwargs):
    try:
        print(*objs, **kwargs)
    except Exception:
        pass

# ======================
#  Tesseract management
# ======================
_TESS_CMD = None
def _ensure_tesseract():
    import shutil, pytesseract
    global _TESS_CMD
    if _TESS_CMD: return _TESS_CMD
    cmd = shutil.which("tesseract")
    candidates = [cmd, r"C:\Program Files\Tesseract-OCR\tesseract.exe", r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"]
    for c in candidates:
        if c and os.path.exists(c):
            pytesseract.pytesseract.tesseract_cmd = c
            _TESS_CMD = c
            return c
    raise FileNotFoundError("tesseract.exe not found")

# =========================
#  Screen grab
# =========================
_sct = None

def ensure_mss():
    global _sct
    if _sct is None:
        _sct = mss.mss()
    return _sct

def grab_monitor_bgr(monitor_idx=1):
    """Grab a specific physical monitor (1, 2, 3...)"""
    sct = ensure_mss()
    monitors = sct.monitors
    
    # Safety check: if they ask for Monitor 2 but only have 1, fallback to 1
    if monitor_idx >= len(monitors):
        _safe_print(f"[vision] Warning: Monitor {monitor_idx} not found. Using Primary (1).")
        monitor_idx = 1
        
    mon = monitors[monitor_idx]
    shot = sct.grab(mon)
    frame = np.array(shot, dtype=np.uint8)
    return cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR), "Monitor " + str(monitor_idx), "Desktop"

def grab_window_or_screen_bgr(grab_mode="window", monitor_idx=1):
    if grab_mode == "screen":
        return grab_monitor_bgr(monitor_idx)
    
    # Default: active window logic (retained for backward compatibility)
    try:
        user32 = ctypes.windll.user32
        hwnd = user32.GetForegroundWindow()
        rect = wt.RECT()
        if hwnd and user32.GetWindowRect(hwnd, ctypes.byref(rect)):
            w = rect.right - rect.left
            h = rect.bottom - rect.top
            if w > 100 and h > 100:
                region = {"left": rect.left, "top": rect.top, "width": w, "height": h}
                sct = ensure_mss()
                shot = sct.grab(region)
                frame = np.array(shot, dtype=np.uint8)
                return cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR), "Active Window", "App"
    except Exception:
        pass
        
    return grab_monitor_bgr(monitor_idx)

# =====================
#  Change detection
# =====================
def quick_change_gate(bgr, last_hash):
    downs = cv2.resize(bgr, (96, 54), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(downs, cv2.COLOR_BGR2GRAY)
    h = int(gray.mean() * 10)
    changed = (last_hash is None) or (abs(h - last_hash) >= 3)
    return changed, h

# =====================
#  OCR (WinRT)
# =====================
def ocr_winrt_top_lines(bgr, max_lines=30, zoom=1.5):
    try:
        import winrt.windows.graphics.imaging as imaging
        import winrt.windows.storage.streams as streams
        import winrt.windows.media.ocr as ocr
        from PIL import Image as PILImage
        from io import BytesIO
    except Exception:
        return []

    h, w = bgr.shape[:2]
    if zoom != 1.0:
        bgr = cv2.resize(bgr, (int(w*zoom), int(h*zoom)), interpolation=cv2.INTER_CUBIC)

    # Convert to bytes for WinRT
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    pil = PILImage.fromarray(rgb)
    buf = BytesIO()
    pil.save(buf, format="PNG")
    data = buf.getvalue()

    # Async OCR
    ras = streams.InMemoryRandomAccessStream()
    writer = streams.DataWriter(ras)
    writer.write_bytes(data)
    writer.store_async().get()
    writer.detach_stream()
    ras.seek(0)
    decoder = imaging.BitmapDecoder.create_async(ras).get()
    software = decoder.get_software_bitmap_async().get()

    engine = ocr.OcrEngine.try_create_from_user_profile_languages()
    result = engine.recognize_async(software).get()
    
    # Return all lines found (up to max)
    lines = [ln.text.strip() for ln in result.lines if ln.text.strip()]
    return lines[:max_lines]

# ============
#  Main loop
# ============
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=r"D:\Echo\state\vision.struct.json")
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--grab", choices=["window", "screen"], default="window")
    ap.add_argument("--monitor", type=int, default=1, help="Monitor Index: 1=Primary, 2=Secondary")
    ap.add_argument("--ocr", choices=["off", "winrt"], default="winrt")
    ap.add_argument("--ocr-lines", type=int, default=30)
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    last_hash = None
    
    _safe_print(f"[vision] Watching Monitor {args.monitor} (Grab: {args.grab})...")

    while True:
        try:
            bgr, title, app = grab_window_or_screen_bgr(args.grab, args.monitor)
            changed, h = quick_change_gate(bgr, last_hash)
            last_hash = h

            if changed:
                data = {
                    "ts": datetime.utcnow().isoformat() + "Z",
                    "window": {"title": title, "app": app},
                    "ocr_top": []
                }

                if args.ocr == "winrt":
                    data["ocr_top"] = ocr_winrt_top_lines(bgr, max_lines=args.ocr_lines)

                # Atomic write
                tmp = args.out + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(data, f, ensure_ascii=False)
                os.replace(tmp, args.out)
                
                _safe_print(f"[vision] Updated: {len(data['ocr_top'])} lines read.")

        except Exception as e:
            _safe_print(f"[vision] Error: {e}")

        time.sleep(args.interval)

if __name__ == "__main__":
    main()