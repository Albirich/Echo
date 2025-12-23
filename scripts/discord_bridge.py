import discord
from discord import app_commands
from discord.ext import commands
import asyncio
import json
import os
import glob
import base64
import aiohttp
from datetime import datetime
import os

# ================= CONFIGURATION =================
TOKEN = os.getenv("DISCORD_BOT_TOKEN")
ECHO_ROOT = r"D:\Echo"
INBOX = os.path.join(ECHO_ROOT, "ui", "discord_inbox")
OUTBOX = os.path.join(ECHO_ROOT, "ui", "discord_outbox")
VISION_ENDPOINT = "http://127.0.0.1:8082/v1/chat/completions"
# =================================================

os.makedirs(INBOX, exist_ok=True)
os.makedirs(OUTBOX, exist_ok=True)

class EchoBot(commands.Bot):
    def __init__(self):
        intents = discord.Intents.default()
        intents.message_content = True
        super().__init__(command_prefix="!", intents=intents)

    async def setup_hook(self):
        print("Syncing command tree...")
        await self.tree.sync()
        print("Command tree synced.")
        self.loop.create_task(check_outbox())

bot = EchoBot()

# --- VISION HANDLER ---
async def analyze_image(attachment, user_text):
    """Downloads image, sends to local Vision Server, returns description."""
    try:
        # 1. Download Image
        print(f"[Vision] Downloading {attachment.filename}...")
        image_bytes = await attachment.read()
        b64_image = base64.b64encode(image_bytes).decode('utf-8')

        # 2. Determine Prompt
        prompt = user_text if user_text else "Describe this image in detail."
        system_prompt = "You are Echo's eyes. Describe what you see to her explicitly. Be detailed."

        # 3. Construct Payload for Vision Server
        payload = {
            "model": "vision",
            "messages": [
                { "role": "system", "content": system_prompt },
                {
                    "role": "user",
                    "content": [
                        { "type": "text", "text": prompt },
                        { "type": "image_url", "image_url": { "url": f"data:image/jpeg;base64,{b64_image}" } }
                    ]
                }
            ],
            "max_tokens": 300,
            "temperature": 0.5
        }

        # 4. Call Local API
        print("[Vision] Calling Vision Server (Port 8082)...")
        async with aiohttp.ClientSession() as session:
            async with session.post(VISION_ENDPOINT, json=payload) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    description = data['choices'][0]['message']['content']
                    print(f"[Vision] Success: {description[:50]}...")
                    return description
                else:
                    err = await resp.text()
                    print(f"[Vision Error] API returned {resp.status}: {err}")
                    return None
    except Exception as e:
        print(f"[Vision Error] {e}")
        return None

# --- INBOX SAVER ---
def save_to_inbox(author, author_id, channel_id, content, image_context=None):
    print(f"[In] {author}: {content} (Has Image: {bool(image_context)})")
    
    # If we have image context, prepend it to the text
    final_text = content if content else ""
    
    payload = {
        "source": "discord",
        "author": author,
        "author_id": str(author_id),
        "channel_id": str(channel_id),
        "text": final_text,
        "image_context": image_context, 
        "ts": datetime.now().isoformat()
    }
    
    timestamp = int(datetime.now().timestamp() * 1000000)
    filename = f"{timestamp}.json"
    try:
        with open(os.path.join(INBOX, filename), 'w', encoding='utf-8') as f:
            json.dump(payload, f, indent=2)
    except Exception as e:
        print(f"Error saving to inbox: {e}")

# --- SLASH COMMAND (Optional fallback) ---
@bot.tree.command(name="echo", description="Talk to Echo explicitly")
async def echo_command(interaction: discord.Interaction, message: str):
    # Just an acknowledgement, real processing happens via inbox
    await interaction.response.send_message(f"**{interaction.user.display_name}**: {message}")
    save_to_inbox(interaction.user.display_name, interaction.user.id, interaction.channel_id, message)

# --- MESSAGE EVENT (THE EARS) ---
@bot.event
async def on_message(message):
    # 1. Don't reply to self
    if message.author == bot.user: return

    # 2. Extract Data
    content = message.content
    has_attachment = len(message.attachments) > 0

    # 3. Vision Processing
    vision_result = None
    if has_attachment:
        att = message.attachments[0]
        # Check if it's an image
        if att.content_type and att.content_type.startswith("image/"):
            # We assume if they sent an image, they want Echo to see it
            async with message.channel.typing():
                vision_result = await analyze_image(att, content)

    # 4. SEND TO BRAIN
    # If there is text OR an image description, send it.
    # We do NOT filter by channel or DM anymore. The PowerShell brain decides if it listens or replies.
    if content or vision_result:
        save_to_inbox(
            author=message.author.display_name, 
            author_id=message.author.id, 
            channel_id=message.channel.id, 
            content=content, 
            image_context=vision_result
        )

# --- OUTBOX WATCHER (THE MOUTH) ---
async def check_outbox():
    await bot.wait_until_ready()
    print(f"Watching for replies in: {OUTBOX}")
    while not bot.is_closed():
        files = glob.glob(os.path.join(OUTBOX, "*.json"))
        for f in files:
            try:
                with open(f, 'r', encoding='utf-8') as file:
                    data = json.load(file)
                
                channel_id = int(data.get("channel_id", 0))
                text = data.get("text", "")
                
                if channel_id and text:
                    channel = bot.get_channel(channel_id)
                    if not channel:
                        try: channel = await bot.fetch_channel(channel_id)
                        except: pass
                    
                    if channel:
                        async with channel.typing():
                            await asyncio.sleep(0.5) # Simulate thought time
                            await channel.send(text)
                        print(f"[Out] Sent to {channel_id}: {text[:30]}...")
                
                os.remove(f)
            except Exception as e:
                print(f"[Error] {e}")
                try: os.remove(f) 
                except: pass
        await asyncio.sleep(0.5)

@bot.event
async def on_ready():
    print(f"Echo Bridge (Full Listen Mode) Online: {bot.user}")

if __name__ == "__main__":
    bot.run(TOKEN)