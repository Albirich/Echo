import argparse
import torch
import ChatTTS
import soundfile as sf
import sys
import os
import re

# --- CONFIG ---
USE_GPU = torch.cuda.is_available() 

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("text", help="Text to speak")
    parser.add_argument("output", help="Output WAV file path")
    parser.add_argument("--seed", type=int, default=2222, help="Voice Seed")
    args = parser.parse_args()

    chat = ChatTTS.Chat()
    try:
        chat.load(compile=False, source="huggingface") 
    except Exception as e:
        sys.exit(1)

    # --- 1. THE "ANTI-DEMON" CLEANER ---
    text = args.text
    # Map actions to safe tokens
    text = text.replace("*laughs*", "[laugh]")
    text = text.replace("*giggles*", "[laugh]")
    text = text.replace("...", "[uv_break]")
    
    # CRITICAL: Remove characters that trigger distortion/screams
    text = text.replace("!", ".").replace("\n", " ").replace("\r", "")
    # Remove anything that isn't a standard letter, number, or basic punctuation
    text = re.sub(r'[^a-zA-Z0-9\s\.\,\?\']', '', text)
    text = text.strip()

    # --- 2. STABLE INFERENCE SETTINGS ---
    # We use a very low temperature (0.1) to prevent "hallucinated" screeching
    params_refine_text = ChatTTS.Chat.RefineTextParams(
        prompt='[oral_2][laugh_0][break_4]', 
    )

    params_infer_code = ChatTTS.Chat.InferCodeParams(
        spk_emb = None,
        temperature = 0.1, # LOW = STABLE/HUMAN. HIGH = DEMON.
        top_P = 0.7,
        top_K = 20,
    )

    if args.seed != -1:
        torch.manual_seed(args.seed)
        params_infer_code.spk_emb = chat.sample_random_speaker()

    print(f"Generating Stable Audio: {text}")
    
    # 3. GENERATE
    wavs = chat.infer(
        [text], 
        use_decoder=True, 
        params_refine_text=params_refine_text,
        params_infer_code=params_infer_code
    )
    
    if wavs and len(wavs) > 0:
        audio_data = wavs[0]
        if hasattr(audio_data, '__len__') and len(audio_data) == 1:
            audio_data = audio_data[0]
        sf.write(args.output, audio_data, 24000)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()