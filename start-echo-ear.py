import os
import time
import speech_recognition as sr
from faster_whisper import WhisperModel
from datetime import datetime

# --- CONFIGURATION ---
MIC_INDEX = 1  # Your OW810 Microphone
MODEL_SIZE = "base.en" # Balanced speed/accuracy
INBOX_DIR = r"D:\Echo\ui\inboxq"
os.makedirs(INBOX_DIR, exist_ok=True)

print(f"--- ECHO EAR (Python Native) ---")

# 1. Load the Model (Runs on GPU)
print(f"Loading {MODEL_SIZE} on GPU...")
try:
    # float16 is much faster on RTX cards
    audio_model = WhisperModel(MODEL_SIZE, device="cuda", compute_type="float16")
    print("SUCCESS: Model Loaded.")
except Exception as e:
    print(f"GPU Error: {e}")
    print("Falling back to CPU (Slower)...")
    audio_model = WhisperModel(MODEL_SIZE, device="cpu", compute_type="int8")

# 2. Setup Microphone
r = sr.Recognizer()
# Energy level to trigger recording (Lower = more sensitive)
r.energy_threshold = 500  
# Stop recording after 0.8 seconds of silence
r.pause_threshold = 0.8   
r.dynamic_energy_threshold = False # Turn off auto-adjust to prevent deafening

def save_to_inbox(text):
    if not text or len(text) < 2: return
    
    # Filter specific Whisper Hallucinations here if they persist
    if text.strip().lower() in ["you", "thank you.", "thanks for watching."]:
        return

    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    filename = f"{timestamp}_user.txt"
    filepath = os.path.join(INBOX_DIR, filename)
    
    try:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(text)
        print(f">> SENT: {text}")
    except Exception as e:
        print(f"Write Error: {e}")

# 3. Main Loop
with sr.Microphone(device_index=MIC_INDEX) as source:
    print(f"Calibrating Mic {MIC_INDEX} for 1 second... (Please be quiet)")
    r.adjust_for_ambient_noise(source, duration=1)
    # Clamp threshold so it doesn't get too high or low
    r.energy_threshold = max(300, min(r.energy_threshold, 2000))
    print(f"Ready. Threshold set to: {r.energy_threshold}")
    print("LISTENING...")

    while True:
        try:
            # A. Listen (Blocks until silence is detected)
            # This handles the "Wait for user to stop talking" logic automatically
            audio_data = r.listen(source, timeout=None)
            
            # B. Transcribe
            # We save to a temp file because faster-whisper likes files
            with open("temp_audio.wav", "wb") as f:
                f.write(audio_data.get_wav_data())
            
            segments, info = audio_model.transcribe("temp_audio.wav", beam_size=5)
            
            # C. Combine segments
            final_text = " ".join([segment.text for segment in segments]).strip()
            
            if final_text:
                print(f"Heard: '{final_text}'")
                save_to_inbox(final_text)
                
        except KeyboardInterrupt:
            break
        except Exception as e:
            # Usually harmless timeouts or noise
            # print(f"Loop Error: {e}") 
            pass