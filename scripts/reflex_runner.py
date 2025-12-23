import time
import sys
import importlib
import traceback
import cv2
import numpy as np
import keyboard  # pip install keyboard
from ultralytics import YOLO
import reflex_logic  # The Hot-Swap Module

# --- CONFIG ---
YOLO_MODEL = "yolo11n.pt"  # Fast, small model
CONF_THRESHOLD = 0.4
# We use a fast screen grabber (dxcam is best for Windows)
try:
    import dxcam
    camera = dxcam.create(output_idx=0, output_color="BGR")
    print("[Reflex] DXCam initialized.")
except:
    print("[Reflex] DXCam missing. Install with 'pip install dxcam'. Falling back to slow grab.")
    camera = None

def get_frame():
    if camera:
        return camera.get_latest_frame()
    return None # Fallback logic omitted for brevity

def main():
    print("[Reflex] Loading YOLO...")
    model = YOLO(YOLO_MODEL)
    print("[Reflex] Engine Started. Waiting for logic...")

    last_mod_time = 0
    
    while True:
        # 1. HOT RELOAD CHECK
        try:
            # Check if Echo rewrote the file
            import os
            mod_time = os.stat("reflex_logic.py").st_mtime
            if mod_time != last_mod_time:
                print("[Reflex] logic file changed. Reloading...")
                time.sleep(0.1) # Let the write finish
                importlib.reload(reflex_logic)
                last_mod_time = mod_time
                print("[Reflex] Brain rewired successfully.")
        except Exception:
            print(f"[Reflex] RELOAD ERROR: {traceback.format_exc()}")
            # We continue with the OLD logic if the new one is broken
        
        # 2. VISION (The Eyes)
        frame = get_frame()
        if frame is None: 
            time.sleep(0.01)
            continue
            
        # Run YOLO (Fast mode)
        results = model.predict(frame, conf=CONF_THRESHOLD, verbose=False, half=True)
        
        # Format for the Lizard Brain
        # List of dicts: [{'label': 'goblin', 'x': 100, 'y': 200, 'w': 50, 'h': 50}]
        vision_data = []
        for r in results[0].boxes:
            box = r.xyxy[0].cpu().numpy()
            cls = int(r.cls[0])
            label = results[0].names[cls]
            vision_data.append({
                "label": label,
                "x": int(box[0]),
                "y": int(box[1]),
                "w": int(box[2] - box[0]),
                "h": int(box[3] - box[1])
            })

        # 3. LOGIC (The Lizard Brain)
        try:
            # THIS is the function Echo edits
            action_log = reflex_logic.tick(vision_data)
            
            if action_log:
                print(f"[Action] {action_log}")
                # Optional: Write this to the blackboard JSON so Main Brain knows what happened
                
        except Exception:
            # If logic crashes, don't kill the runner. Just print error.
            # This handles syntax errors Echo might introduce.
            pass # traceback.print_exc() (enable for debug)

if __name__ == "__main__":
    main()