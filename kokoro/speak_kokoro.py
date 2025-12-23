import sys
import argparse
import soundfile as sf
from kokoro_onnx import Kokoro
import time
import os

# --- CONFIG ---
MODEL_PATH = "D:/Echo/Kokoro/kokoro-v0_19.onnx"
VOICES_PATH = "D:/Echo/Kokoro/voices.bin"
DEFAULT_VOICE = "af_heart"  # "af_bella", "af_nicole", "af_sarah" are good female voices

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("text", help="Text to speak")
    parser.add_argument("output", help="Output WAV file path")
    parser.add_argument("--voice", default=DEFAULT_VOICE, help="Voice ID")
    args = parser.parse_args()

    if not os.path.exists(MODEL_PATH):
        print(f"ERROR: Model not found at {MODEL_PATH}")
        sys.exit(1)

    # Load Model
    kokoro = Kokoro(MODEL_PATH, VOICES_PATH)
    
    # Generate
    # print(f"Generating: {args.text[:30]}...")
    samples, sample_rate = kokoro.create(
        args.text, 
        voice=args.voice, 
        speed=1.0, 
        lang="en-us"
    )

    # Save
    sf.write(args.output, samples, sample_rate)
    # print(f"Saved to {args.output}")

if __name__ == "__main__":
    main()