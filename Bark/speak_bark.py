import argparse
import os
import sys
import torch
from scipy.io.wavfile import write as write_wav

# --- SPEED HACKS ---
# 1. Force the Lightweight Models (Much faster, slightly less variety)
os.environ["SUNO_USE_SMALL_MODELS"] = "True"
# 2. Suppress TensorFlow/Torch logs
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3" 

print("Initializing Bark (Fast Mode)...")
from bark import SAMPLE_RATE, generate_audio, preload_models

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("text", help="Text to speak")
    parser.add_argument("output", help="Output WAV file path")
    parser.add_argument("--voice", default="v2/en_speaker_9", help="Voice Preset")
    args = parser.parse_args()

    # DIAGNOSTIC: Confirm Hardware
    if torch.cuda.is_available():
        vram = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"[STATUS] Running on GPU: {torch.cuda.get_device_name(0)} ({vram:.1f} GB)")
    else:
        print("[WARNING] Running on CPU! This will be slow (1m+). Check your torch installation.")

    # Preload models (Text, Coarse, Fine)
    # This happens once when the script starts
    preload_models()

    # --- EMOTION MAPPING ---
    text = args.text
    text = text.replace("*laughs*", "[laughter]")
    text = text.replace("*giggles*", "[laughter]")
    text = text.replace("*sighs*", "[sighs]")
    text = text.replace("*gasps*", "[gasps]")
    # Bark needs clear separation for sound tags
    text = text.replace("[", " [").replace("]", "] ") 
    text = text.replace("...", " ... ") 

    print(f"Generating ({args.voice}): {text}")

    try:
        # Generate Audio
        audio_array = generate_audio(text, history_prompt=args.voice)

        # Save to disk
        write_wav(args.output, SAMPLE_RATE, audio_array)
        print(f"Saved to {args.output}")

    except Exception as e:
        print(f"Error generating audio: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()