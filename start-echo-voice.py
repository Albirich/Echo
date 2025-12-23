import time
import os
import shutil
import outetts
import re

# --- CONFIGURATION ---
MODEL_PATH = r"D:\Echo\Models\OuteTTS-0.2-500M-Q5_K_M.gguf"
INBOX_DIR = r"D:\Echo\ui\inbox_voice"
PROCESSED_DIR = r"D:\Echo\ui\processed_voice"
AUDIO_OUTPUT = r"D:\Echo\VoiceOutput\echo_out.wav"
REF_AUDIO = r"D:\Echo\config\reference_voice.wav"

print("--- ECHO VOICE ENGINE (Final Production) ---")

# 1. Initialize Engine
try:
    print(f"Loading Model...")
    config = outetts.GGUFModelConfig_v1(
        model_path=MODEL_PATH,
        language="en",
        n_gpu_layers=99
    )
    interface = outetts.InterfaceGGUF(model_version="0.2", cfg=config)
    print("SUCCESS: Engine Loaded.")
except Exception as e:
    print(f"\nCRITICAL LOAD ERROR: {e}")
    exit()

os.makedirs(INBOX_DIR, exist_ok=True)
os.makedirs(PROCESSED_DIR, exist_ok=True)

# 2. Load Speaker
speaker = None
if os.path.exists(REF_AUDIO):
    try:
        print("Loading Profile...")
        speaker = interface.create_speaker(REF_AUDIO)
        print("SUCCESS: Profile Loaded.")
    except Exception as e:
        print(f"Profile Error: {e}")

print(f"Watching {INBOX_DIR}...")

while True:
    for filename in os.listdir(INBOX_DIR):
        if filename.endswith(".txt"):
            file_path = os.path.join(INBOX_DIR, filename)
            print(f"Processing: {filename}")
            
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    raw_text = f.read()
                    clean_text = re.sub(r'\[.*?\]', '', raw_text).strip()
                    if not clean_text: clean_text = "System online."
                    if clean_text[-1] not in ".!?": clean_text += "."
                        
                print(f"Reading: '{clean_text}'")
                t_start = time.time()

                # --- GENERATION ---
                output = interface.generate(
                    text=clean_text,
                    speaker=speaker,
                    temperature=0.4, 
                    repetition_penalty=1.1,
                    max_length=2048 # Fixed: Increased to prevent cutoff
                )
                
                print(f"Generation Time: {time.time() - t_start:.2f}s")

                output.save(AUDIO_OUTPUT)
                
                import winsound
                winsound.PlaySound(AUDIO_OUTPUT, winsound.SND_FILENAME)
                shutil.move(file_path, os.path.join(PROCESSED_DIR, filename))

            except Exception as e:
                print(f"ERROR: {e}")
                if os.path.exists(file_path):
                    shutil.move(file_path, os.path.join(PROCESSED_DIR, "crashed_" + filename))
    
    time.sleep(0.1)