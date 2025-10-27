import argparse, json, time, os, ctypes, sys
from datetime import datetime
import ctypes.wintypes as wt
import numpy as np
import mss, cv2
from PIL import Image

# =========================
#  Process & console setup
# =========================
# Make this process DPI-aware so Win32 window rects are in PHYSICAL pixels
try:
    ctypes.windll.user32.SetProcessDPIAware()
except Exception:
    pass

# Ensure console printing never crashes on Windows due to encoding
try:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        sys.stdout.reconfigure(errors="replace")
        sys.stderr.reconfigure(errors="replace")
except Exception:
    pass

def _safe_print(*objs, **kwargs):
    """Print that tolerates any characters by replacing unencodable ones."""
    try:
        print(*objs, **kwargs)
        return
    except UnicodeEncodeError:
        enc = getattr(sys.stdout, "encoding", None) or "ascii"
        safe_objs = []
        for o in objs:
            s = str(o)
            try:
                safe_objs.append(s.encode(enc, errors="replace").decode(enc, errors="replace"))
            except Exception:
                safe_objs.append("".join(ch if ord(ch) < 128 else "?" for ch in s))
        print(*safe_objs, **kwargs)

# ======================
#  Tesseract management
# ======================
_TESS_CMD = None

def _ensure_tesseract():
    """Find tesseract.exe and set pytesseract + TESSDATA_PREFIX."""
    import shutil, pytesseract
    global _TESS_CMD
    if _TESS_CMD:
        return _TESS_CMD

    cmd = shutil.which("tesseract")
    candidates = [
        cmd,
        r"C:\\Program Files\\Tesseract-OCR\\tesseract.exe",
        r"C:\\Program Files (x86)\\Tesseract-OCR\\tesseract.exe",
    ]
    for c in candidates:
        if c and os.path.exists(c):
            pytesseract.pytesseract.tesseract_cmd = c
            tessdir = os.path.join(os.path.dirname(c), "tessdata")
            os.environ["TESSDATA_PREFIX"] = tessdir if os.path.isdir(tessdir) else os.path.dirname(c)
            _TESS_CMD = c
            _safe_print(f"[vision][ocr] using tesseract at: {c}", flush=True)
            return c
    raise FileNotFoundError("tesseract.exe not found in PATH or common locations")

# =========================
#  Active window utilities
# =========================

def get_active_window_bbox():
    user32 = ctypes.windll.user32
    hwnd = user32.GetForegroundWindow()
    rect = wt.RECT()
    if hwnd and user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return rect.left, rect.top, rect.right, rect.bottom, hwnd
    return None

def get_window_title(hwnd):
    if not hwnd:
        return ""
    GetWindowTextW = ctypes.windll.user32.GetWindowTextW
    GetWindowTextLengthW = ctypes.windll.user32.GetWindowTextLengthW
    length = GetWindowTextLengthW(hwnd) + 1
    buff = ctypes.create_unicode_buffer(length)
    GetWindowTextW(hwnd, buff, length)
    return buff.value.strip()

def get_process_exe(hwnd):
    try:
        import psutil, win32process
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        return psutil.Process(pid).name()
    except Exception:
        return ""

# ==============
#  Screen grab
# ==============
_sct = None
_monitors = None  # list of monitor dicts (0 = virtual desktop)


def ensure_mss():
    global _sct, _monitors
    if _sct is None:
        _sct = mss.mss()
        _monitors = _sct.monitors  # [0] = virtual, [1..] = physical monitors
    return _sct, _monitors


def grab_region_bgr(region):
    sct, _ = ensure_mss()
    shot = sct.grab(region)
    frame = np.array(shot, dtype=np.uint8)  # BGRA
    return cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)


def grab_window_or_screen_bgr(grab_mode="window"):
    """Capture BGR frame and annotate with active window metadata.
    - grab_mode == 'window': capture the foreground window
    - grab_mode == 'screen': capture full virtual desktop, but still report active title/app
    """
    sct, mons = ensure_mss()

    # Attempt to resolve active window info regardless of grab mode
    active_title, active_app, hwnd = "", "", None
    try:
        bbox = get_active_window_bbox()
        if bbox:
            x0, y0, x1, y1, hwnd = bbox
            active_title = get_window_title(hwnd)
            active_app = get_process_exe(hwnd)
    except Exception:
        pass

    if grab_mode == "screen":
        # Use virtual desktop (all monitors) for broad context
        mon = mons[0]
        bgr = grab_region_bgr(mon)
        return bgr, active_title, active_app

    # Default: active-window capture
    if not hwnd:
        # Fallback: virtual desktop
        mon = mons[0]
        bgr = grab_region_bgr(mon)
        return bgr, active_title, active_app

    # Clamp to virtual desktop
    mon = mons[0]
    L, T, W, H = mon["left"], mon["top"], mon["width"], mon["height"]
    x0 = max(L, min(L + W - 1, x0)); x1 = max(L + 1, min(L + W, x1))
    y0 = max(T, min(T + H - 1, y0)); y1 = max(T + 1, min(T + H, y1))

    ww, hh = (x1 - x0), (y1 - y0)
    if ww < 200 or hh < 80:  # Degenerate/overlay: fall back to virtual desktop
        bgr = grab_region_bgr(mon)
        return bgr, active_title, active_app

    region = {"left": x0, "top": y0, "width": ww, "height": hh}
    bgr = grab_region_bgr(region)
    return bgr, active_title, active_app

# =====================
#  Change detection gate
# =====================

def quick_change_gate(bgr, last_hash):
    downs = cv2.resize(bgr, (96, 54), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(downs, cv2.COLOR_BGR2GRAY)
    h = int(gray.mean() * 10)
    changed = (last_hash is None) or (abs(h - last_hash) >= 3)
    return changed, h

# =====================
#  Optional CLIP tags
# =====================
_CLIP = None
_VOCAB = [
    "screen with text", "dialog window", "menu", "chat window", "code editor",
    "webpage", "video player", "map", "spreadsheet", "email client", "file explorer",
    "person", "hand", "face", "avatar", "game character", "skeleton", "zombie",
    "weapon", "inventory", "health bar", "minimap", "settings panel", "button",
    "chart", "table", "graph", "form", "notification", "popup"
]


def get_clip(device="cpu"):
    global _CLIP
    if _CLIP:
        return _CLIP
    try:
        import torch, open_clip
        model, _, preprocess = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai")
        tok = open_clip.get_tokenizer("ViT-B-32")
        device = "cuda" if (device != "cpu" and torch.cuda.is_available()) else "cpu"
        model = model.to(device)
        with torch.no_grad():
            text = tok([f"a screenshot of {t}" for t in _VOCAB]).to(device)
            text_emb = model.encode_text(text)
            text_emb = text_emb / text_emb.norm(dim=-1, keepdim=True)
        _CLIP = (model, preprocess, text_emb, device)
        return _CLIP
    except Exception:
        _CLIP = None
        return None


def clip_tags(bgr, topk=3, device="cpu"):
    mod = get_clip(device=device)
    if not mod:
        return []
    import torch
    model, preprocess, text_emb, dev = mod
    rgb = cv2.cvtColor(cv2.resize(bgr, (384, int(bgr.shape[0] * 384 / bgr.shape[1]))), cv2.COLOR_BGR2RGB)
    pil = Image.fromarray(rgb)
    with torch.no_grad():
        img = preprocess(pil).unsqueeze(0).to(dev)
        img_emb = model.encode_image(img)
        img_emb = img_emb / img_emb.norm(dim=-1, keepdim=True)
        sims = (img_emb @ text_emb.T).squeeze(0)
        vals, idxs = sims.topk(min(topk, len(_VOCAB)))
        return [{"name": _VOCAB[i], "score": round(float(v), 3)} for v, i in zip(vals.tolist(), idxs.tolist())]

# ===============
#  OCR backends
# ===============

def ocr_winrt_top_lines(bgr, max_lines=5, zoom=1.7, debug=False):
    """WinRT OCR with in-memory PNG, optional upscale/sharpen."""
    try:
        import winrt.windows.graphics.imaging as imaging
        import winrt.windows.storage.streams as streams
        import winrt.windows.media.ocr as ocr
        from io import BytesIO
        from PIL import Image as PILImage
    except Exception:
        return []

    h, w = bgr.shape[:2]
    if w < 300 or h < 120:
        return []

    # Upscale + mild unsharp mask helps with thin UI fonts
    if zoom and zoom != 1.0:
        nh, nw = int(h * zoom), int(w * zoom)
        bgr = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_CUBIC)
        blur = cv2.GaussianBlur(bgr, (0, 0), 1.0)
        bgr = cv2.addWeighted(bgr, 1.4, blur, -0.4, 0)

    if debug:
        try:
            cv2.imwrite(r"D:\Echo\state\vision.ocr.debug.jpg", bgr)
        except Exception:
            pass

    # Encode as PNG in-memory (BGRA)
    bgra = cv2.cvtColor(bgr, cv2.COLOR_BGR2BGRA)
    pil = PILImage.fromarray(bgra, mode="RGBA")
    from io import BytesIO
    buf = BytesIO()
    pil.save(buf, format="PNG")
    data = buf.getvalue()

    # Load into SoftwareBitmap
    ras = streams.InMemoryRandomAccessStream()
    writer = streams.DataWriter(ras)
    writer.write_bytes(data)
    writer.store_async().get()
    writer.detach_stream()
    ras.seek(0)
    decoder = imaging.BitmapDecoder.create_async(ras).get()
    software = decoder.get_software_bitmap_async().get()

    engine = ocr.OcrEngine.try_create_from_user_profile_languages()
    if engine is None:
        return []
    result = engine.recognize_async(software).get()
    lines = [ln.text.strip() for ln in result.lines if ln.text and ln.text.strip()]
    return lines[:max_lines]


def _build_lines_from_data(data, min_conf=60, max_lines=5):
    # Group words by (page, block, par, line), then join left->right
    N = len(data.get("text", []))
    groups = {}
    for i in range(N):
        text = (data["text"][i] or "").strip()
        conf_raw = str(data["conf"][i])
        try:
            conf = int(float(conf_raw))
        except Exception:
            try:
                conf = int(conf_raw)
            except Exception:
                conf = -1
        if not text or conf < min_conf:
            continue
        key = (data.get("page_num", [0])[i], data.get("block_num", [0])[i], data.get("par_num", [0])[i], data.get("line_num", [0])[i])
        left = int(data.get("left", [0])[i]) if isinstance(data.get("left", [0])[i], (int, float)) else 0
        groups.setdefault(key, []).append((left, text))
    import unicodedata, re
    def clean_line(s: str) -> str:
        s = unicodedata.normalize("NFKC", s)
        s = re.sub(r"\s+", " ", s)
        return s.strip()
    lines = []
    for key, words in groups.items():
        words.sort(key=lambda t: t[0])
        joined = clean_line(" ".join([w for _, w in words]))
        if joined:
            lines.append(joined)
    # Prefer longer informative lines
    lines.sort(key=lambda s: (-len(s), s))
    # Deduplicate while preserving order
    seen = set(); out = []
    for ln in lines:
        if ln not in seen:
            seen.add(ln); out.append(ln)
        if len(out) >= max_lines:
            break
    return out


def ocr_tesseract_lines(bgr, max_lines=5, zoom=1.3, debug=True, psm=None):
    import pytesseract
    from pytesseract import Output
    _ensure_tesseract()

    h, w = bgr.shape[:2]
    if w < 300 or h < 120:
        return []

    # Heuristic upscale for small regions
    if zoom and zoom != 1.0 and max(w, h) < 1400:
        bgr = cv2.resize(bgr, (int(w * zoom), int(h * zoom)), interpolation=cv2.INTER_CUBIC)

    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    # Gentle denoise + contrast boost (avoid hard binarization that causes artifacts)
    try:
        gray = cv2.bilateralFilter(gray, 7, 50, 50)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        gray = clahe.apply(gray)
    except Exception:
        pass

    if debug:
        try:
            cv2.imwrite(r"D:\Echo\state\vision.ocr.debug.jpg", gray)
        except Exception:
            pass

    # Use sparse-text PSM for large captures; single-block for smaller crops
    use_psm = psm if psm is not None else (11 if max(w, h) >= 1800 else 6)
    config = f"--oem 1 --psm {use_psm} -l eng"
    try:
        data = pytesseract.image_to_data(gray, config=config, output_type=Output.DICT)
        return _build_lines_from_data(data, min_conf=60, max_lines=max_lines)
    except Exception:
        # Fallback to simple string API
        txt = pytesseract.image_to_string(gray, config=config)
        lines = [ln.strip() for ln in txt.splitlines() if ln.strip()]
        return lines[:max_lines]

# ==================
#  Layout heuristic
# ==================

def guess_layout(bgr):
    h, w = bgr.shape[:2]
    downs = cv2.resize(bgr, (128, 72), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(downs, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 60, 120)
    col_sum = edges.sum(axis=0) / 255.0
    left = col_sum[:32].mean()
    center = col_sum[48:80].mean()
    right = col_sum[96:].mean()
    buckets = [("left panel", left), ("center content", center), ("right panel", right)]
    buckets.sort(key=lambda x: -x[1])
    top = [b[0] for b in buckets if b[1] > 0.15]
    if not top:
        top = ["center content"]
    return ", ".join(top)

# ============
#  Main loop
# ============

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=r"D:\Echo\state\vision.struct.json")
    ap.add_argument("--interval", type=float, default=1.5)
    ap.add_argument("--preview", action="store_true")
    ap.add_argument("--tags", action="store_true", help="enable zero-shot CLIP tags")
    ap.add_argument("--tags-device", choices=["cpu", "cuda"], default="cpu")
    ap.add_argument("--grab", choices=["window", "screen"], default="window", help="what to capture")
    ap.add_argument("--ocr", choices=["off", "winrt", "tesseract"], default="winrt")
    ap.add_argument("--ocr-lines", type=int, default=5)
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    last_hash = None
    wrote_once = False

    _safe_print("[vision] starting fast probe...", flush=True)

    while True:
        bgr, title, app = grab_window_or_screen_bgr(args.grab)
        changed, h = quick_change_gate(bgr, last_hash)
        last_hash = h

        if (not wrote_once) or changed:
            data = {
                "ts": datetime.utcnow().isoformat() + "Z",
                "window": {"title": title, "app": app, "size": [int(bgr.shape[1]), int(bgr.shape[0])]},
                "layout": guess_layout(bgr),
                "tags": [],
            }

            # OCR
            data["ocr_top"] = []
            try:
                # Prefer OCR on active-window region when grabbing full screen
                ocr_src = bgr
                if args.grab == "screen":
                    try:
                        # Map active window rect to screen-relative crop if available
                        bbox = get_active_window_bbox()
                        if bbox and _monitors:
                            x0, y0, x1, y1, _ = bbox
                            mon = _monitors[0]
                            L, T, W, H = mon["left"], mon["top"], mon["width"], mon["height"]
                            rx0 = max(0, min(W - 1, x0 - L)); rx1 = max(1, min(W, x1 - L))
                            ry0 = max(0, min(H - 1, y0 - T)); ry1 = max(1, min(H, y1 - T))
                            if rx1 > rx0 + 200 and ry1 > ry0 + 80:
                                ocr_src = bgr[ry0:ry1, rx0:rx1]
                    except Exception:
                        pass

                if args.ocr == "winrt":
                    data["ocr_top"] = ocr_winrt_top_lines(ocr_src, max_lines=args.ocr_lines, zoom=1.7, debug=True)
                elif args.ocr == "tesseract":
                    data["ocr_top"] = ocr_tesseract_lines(ocr_src, max_lines=args.ocr_lines, zoom=1.3, debug=True)
            except Exception as e:
                _safe_print(f"[vision][ocr] error: {e}", flush=True)

            # CLIP tags
            if args.tags:
                try:
                    data["tags"] = clip_tags(bgr, topk=3, device=args.tags_device)
                except Exception:
                    data["tags"] = []

            # Atomic write to avoid readers seeing partial JSON
            tmp = args.out + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, args.out)

            if args.preview:
                try:
                    cv2.imwrite(r"D:\Echo\state\vision.preview.jpg", bgr)
                except Exception:
                    pass

            wrote_once = True
            try:
                _safe_print(
                    f"[vision] tick  title='{(title or '')[:60]}'  app='{app or ''}'  ocr={len(data.get('ocr_top', []))} lines  "
                    f"tags={[t.get('name','') for t in data.get('tags', [])]}  -> {args.out}",
                    flush=True,
                )
            except Exception:
                # Extreme fallback: ASCII-only
                def _ascii(s: str) -> str:
                    try:
                        return (s or '').encode('ascii', errors='replace').decode('ascii', errors='replace')
                    except Exception:
                        return ''.join(ch if ord(ch) < 128 else '?' for ch in (s or ''))
                t_ascii = _ascii((title or '')[:60])
                a_ascii = _ascii(app or '')
                tags_ascii = [_ascii(t.get('name','')) for t in data.get('tags', [])]
                print(f"[vision] tick  title='{t_ascii}'  app='{a_ascii}'  ocr={len(data.get('ocr_top', []))} lines  tags={tags_ascii}  -> {args.out}", flush=True)

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
