import argparse, json, time, sys
from datetime import datetime
import numpy as np, cv2
from ultralytics import YOLO
# --- Zero-shot CLIP relabeler ---
import torch, open_clip

# A broad, generic vocab (edit/extend later; order doesn't matter)
GENERIC_VOCAB = [
    "skeleton", "zombie", "ghost", "vampire", "goblin", "orc", "troll",
    "dragon", "knight", "archer", "mage", "witch", "demon", "angel",
    "robot", "mech", "monster", "beast", "slime",
    "ally", "enemy", "npc", "merchant", "boss",
    "sword", "axe", "bow", "staff", "shield", "gun",
    "health potion", "mana potion", "treasure chest", "coin",
    "projectile", "fireball", "arrow", "bullet",
    "status effect icon", "quest icon", "map icon", "inventory icon", "HUD icon",
    "door", "key", "trap", "portal", "altar", "statue", "sarcophagus", "armor"
]

def build_clip(device="cuda"):
    model, _, preprocess = open_clip.create_model_and_transforms("ViT-B-32", pretrained="openai")
    tokenizer = open_clip.get_tokenizer("ViT-B-32")
    model = model.to(device)
    with torch.no_grad():
        text_tokens = tokenizer([f"a photo of a {t}" for t in GENERIC_VOCAB]).to(device)
        text_emb = model.encode_text(text_tokens)
        text_emb = text_emb / text_emb.norm(dim=-1, keepdim=True)
    return model, preprocess, text_emb

_CLIP = None  # lazy init
def relabel_with_clip(bgr, objects, conf_boost=0.15, device="cuda"):
    global _CLIP
    if _CLIP is None:
        _CLIP = build_clip("cuda" if device!="cpu" and torch.cuda.is_available() else "cpu")
    model, preprocess, text_emb = _CLIP
    H, W = bgr.shape[:2]
    results = []
    with torch.no_grad():
        for obj in objects:
            x0,y0,x1,y1 = map(int, obj["bbox"])
            x0 = max(0, min(W-1, x0)); x1 = max(1, min(W, x1))
            y0 = max(0, min(H-1, y0)); y1 = max(1, min(H, y1))
            if x1<=x0 or y1<=y0:
                results.append(obj); continue
            crop = bgr[y0:y1, x0:x1, ::-1]  # to RGB for CLIP preprocess
            import PIL.Image as Image
            pil = Image.fromarray(crop)
            img = preprocess(pil).unsqueeze(0).to(text_emb.device)
            img_emb = model.encode_image(img)
            img_emb = img_emb / img_emb.norm(dim=-1, keepdim=True)
            # cosine similarity
            sims = (img_emb @ text_emb.T).squeeze(0)
            topv, topi = sims.topk(1)
            zz_name = GENERIC_VOCAB[int(topi.item())]
            zz_score = float(topv.item())  # ~[-1,1]
            # if CLIP is confident and YOLO label is generic (e.g., "person"), adopt it
            label = obj["label"]
            if label in ("person","sports ball","cell phone","book","bottle","cup","chair","tv"):
                # convert CLIP cosine to ~[0..1] feel (optional)
                obj["label_clip"] = zz_name
                obj["clip_sim"] = round(zz_score, 3)
                if zz_score > 0.30:  # tune threshold
                    obj["label"] = zz_name
                    # gently lift conf if CLIP is confident
                    obj["conf"] = round(min(1.0, obj["conf"] + conf_boost), 3)
            else:
                obj["label_clip"] = zz_name
                obj["clip_sim"] = round(zz_score, 3)
            results.append(obj)
    return results


def _print(*a): print('[yolo_watch]', *a, flush=True)

def get_dxcam():
    try:
        import dxcam
        cam = dxcam.create(output_idx=0)
        cam.start(target_fps=30, video_mode=True)
        def grab():
            f = cam.get_latest_frame()
            if f is None: return None
            return cv2.cvtColor(f, cv2.COLOR_RGB2BGR)
        grab._stop = lambda: cam.stop()
        _print('dxcam ready')
        return grab
    except Exception as e:
        _print('dxcam unavailable:', repr(e))
        return None

def get_mss():
    try:
        import mss
        sct = mss.mss()
        mon = sct.monitors[1]
        def grab():
            shot = sct.grab(mon)  # BGRA
            f = np.array(shot, dtype=np.uint8)
            return cv2.cvtColor(f, cv2.COLOR_BGRA2BGR)
        grab._stop = lambda: None
        _print('mss ready')
        return grab
    except Exception as e:
        _print('mss unavailable:', repr(e))
        return None

def get_grabber(force):
    if force == 'dxcam': return get_dxcam()
    if force == 'mss':   return get_mss()
    return get_dxcam() or get_mss()

def summarize(dets, names):
    counts, objects = {}, []
    for b in dets.boxes:
        c = int(b.cls); label = names.get(c, str(c)) if isinstance(names, dict) else str(c)
        conf = float(b.conf); xyxy = [float(v) for v in b.xyxy[0].tolist()]
        counts[label] = counts.get(label, 0) + 1
        objects.append({'label': label, 'bbox': xyxy, 'conf': round(conf, 3)})
    summary = 'No objects detected.' if not objects else 'Detected ' + ', '.join(f'{k}:{v}' for k,v in sorted(counts.items(), key=lambda kv: -kv[1])[:5])
    return summary, counts, objects

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--imgsz', type=int, default=512)
    ap.add_argument('--conf', type=float, default=0.35)
    ap.add_argument('--interval', type=float, default=2.0)
    ap.add_argument('--device', type=int, default=0)  # 0 GPU; -1 CPU
    ap.add_argument('--out', type=str, default=r'D:\Echo\state\screen.struct.json')
    ap.add_argument('--model', type=str, default='yolo11n.pt')
    ap.add_argument('--grab', type=str, choices=['auto','dxcam','mss'], default='auto')
    args = ap.parse_args()

    grab = get_grabber(args.grab if args.grab!='auto' else None)
    if grab is None: raise RuntimeError('No screen grabber available')

    model = YOLO(args.model)
    names = getattr(model.model, 'names', getattr(model, 'names', {}))

    last_hash, wrote_once = None, False
    try:
        while True:
            frame = grab()
            if frame is None:
                _print('no frame, retrying...')
                time.sleep(0.1); continue

            downs = cv2.resize(frame, (64,36))
            h = int(downs.mean())
            need_tick = (last_hash is None) or (abs(h - last_hash) >= 2)
            last_hash = h

            if not need_tick and wrote_once:
                time.sleep(args.interval); continue

            res = model.predict(
                frame[:, :, ::-1],
                imgsz=args.imgsz, conf=args.conf,
                device=args.device if args.device >= 0 else 'cpu',
                half=True if args.device >= 0 else False,
                verbose=False,
            )
            r0 = res[0]
            summary, counts, objects = summarize(r0, names)
            # relabel using CLIP zero-shot to get game-ish semantics (skeleton, goblin, etc.)
            objects = relabel_with_clip(frame, objects, conf_boost=0.15, device="cuda" if args.device>=0 else "cpu")

            # rebuild counts/summary from relabeled objects
            from collections import Counter
            _counts = Counter([o["label"] for o in objects])
            counts = dict(_counts)
            summary = "No objects detected." if not objects else \
                    "Detected " + ", ".join(f"{k}:{v}" for k,v in sorted(counts.items(), key=lambda kv: -kv[1])[:5])
            out = {
                'timecode': datetime.utcnow().isoformat() + 'Z',
                'imgsz': args.imgsz, 'conf': args.conf,
                'summary': summary, 'counts': counts, 'objects': objects,
                'notes': ['yolo-normal-vision'],
            }
            with open(args.out, 'w', encoding='utf-8') as f:
                json.dump(out, f, ensure_ascii=False)

            wrote_once = True
            _print(f'tick: {summary} -> {args.out}')
            time.sleep(args.interval)
    finally:
        try: grab._stop()
        except Exception: pass

if __name__=='__main__': main()
