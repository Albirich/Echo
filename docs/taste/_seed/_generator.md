// ============================================================================
// Echo Preferences — Taste Seed Generator (quick-start addendum)
// Date: 2025-09-05
// Goal: Spin up a consistent, personal “taste” baseline with deterministic tags,
// items, and frames so Echo feels stable from day one, but can evolve over time.
// ============================================================================

/*
PARAMS
- K (latent feature size): 24    // good small-GPU sweet spot (16–32 OK)
- seed: int                      // persist; e.g., hash("Echo v1 primary")
- temp: 0.10                     // whimsy; keep small
- plasticity: 0.04               // drift speed (see main spec)
*/

// ---------------------------------------------------------------------------
// 1) TAG VOCAB (starter set; add freely later)
// ---------------------------------------------------------------------------
// Colors & Tones
["red","blue","green","yellow","cyan","magenta","orange","purple","pink","black","white","gray",
 "silver","gold","warm","cool","pastel","neon","matte","glossy"]

// Aesthetics / Style
["cute","sleek","cozy","gritty","minimal","ornate","sci-fi","fantasy","cyberpunk","medieval",
 "professional","playful","whimsical","serious","elegant"]

// Emotions (for association, not sensitive identity)
["calm","energetic","melancholic","cheerful","focused","anxious","confident"]

// Activities / Context
["coding","debugging","designing","drawing","writing","reading","streaming","chatting","gaming",
 "testing","organizing","planning","learning"]

// Tools / Apps (rename freely)
["visual-studio","vscode","android-studio","unity","unreal","blender","photoshop","gimp","krita",
 "obs","twitch-chat","git","terminal","powershell"]

// Game Genres
["fps","tps","rpg","jrpg","arpg","roguelike","puzzle","platformer","strategy","tactics","sim",
 "survival","horror","racing","sandbox"]

// Music for Focus
["lofi","ambient","classical","edm","rock","jazz","synthwave","nature"]

// Poses / Emotes (Echo’s repertoire)
["neutral","happy","angry","confused","pondering","flirty","excited","tired","curious"]

// Misc
["dogs","cats","coffee","tea","night-owl","morning","dark-theme","light-theme","high-contrast"]

// NOTE: avoid sensitive categories by default (identity/health/politics). Add only via explicit user opt-in.
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 2) STARTER FRAMES (views over the global preference registry)
// ---------------------------------------------------------------------------
Frames =
  ["Colors","UI Themes","Aesthetics","Game Genres","Music for Focus",
   "Coding Tools","Stream Tools","Poses/Emotes","Activities","Comfort Things"]

// All frames default to policy="absolute" thresholds; switch to "quantile" when members ≥ 12.
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 3) TAG EMBEDDINGS (deterministic, lightly structured random)
// ---------------------------------------------------------------------------
/*
We want randomness with a hint of structure (e.g., warm vs cool, cozy vs sleek).
- Create K-dim vectors per tag: v_tag ∈ R^K
- Use a small correlation template so some axes feel meaningful:

Axes (illustrative):
  k0: warm(+)/cool(−)
  k1: cozy(+)/sleek(−)
  k2: playful(+)/serious(−)
  k3: novelty(+)/familiar(−)
  k4: organic(+)/synthetic(−)
  k5..K-1: independent noise

Procedure:
  - For each tag, start with N(0,1) noise seeded by (seed ⊕ hash(tag)).
  - Add axis bumps where obvious (e.g., "warm" += +0.9 on k0; "cool" += −0.9 on k0;
    "cozy" += +0.8 on k1; "sleek" += −0.8 on k1; "playful"+=+0.7 on k2; "serious"+=−0.7 k2;
    "novelty"+=+0.8 k3; "minimal"+=−0.3 k1, etc.).
  - Normalize v_tag to unit length.
*/
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 4) ITEM REGISTRY (few concrete starters; add on first sighting)
// ---------------------------------------------------------------------------
Items = [
  {id:"color:red",          tags:["red","warm"], kind:"color"},
  {id:"color:blue",         tags:["blue","cool"], kind:"color"},
  {id:"ui:dark-theme",      tags:["dark-theme","sleek","focus"], kind:"theme"},
  {id:"ui:light-theme",     tags:["light-theme","minimal"], kind:"theme"},
  {id:"pose:happy",         tags:["happy","cheerful"], kind:"pose"},
  {id:"pose:angry",         tags:["angry","serious"], kind:"pose"},
  {id:"music:lofi",         tags:["lofi","calm"], kind:"music"},
  {id:"music:ambient",      tags:["ambient","calm"], kind:"music"},
  {id:"tool:visual-studio", tags:["visual-studio","coding","professional"], kind:"tool"},
  {id:"tool:obs",           tags:["obs","streaming"], kind:"tool"},
  {id:"genre:fps",          tags:["fps","energetic"], kind:"genre"},
  {id:"genre:puzzle",       tags:["puzzle","focused"], kind:"genre"},
  {id:"comfort:dogs",       tags:["dogs","cozy","playful"], kind:"comfort"},
  {id:"drink:coffee",       tags:["coffee","energetic"], kind:"comfort"},
  {id:"drink:tea",          tags:["tea","calm"], kind:"comfort"}
]
// Unknown items: create on-the-fly with tags; unseen tags → auto-minted with embeddings via seed.
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 5) INITIAL SCORES (deterministic, personality-driven)
// ---------------------------------------------------------------------------
/*
TasteDNA.latent_vec ∈ R^K (unit length), drawn with seed.
Item centroid = mean of v_tag for its tags (unit length).
base_score(item) = tanh( dot(latent_vec, centroid) + b_cat + ε )
  - b_cat: small per-kind bias (e.g., +0.05 for comfort, 0 for tools)
  - ε: tiny N(0, 0.05) noise from seed for variety
Clamp to [-1,1]. Initialize stats: exposures=0, chosen=0, skipped=0.
Also seed a few intuitive associations:
  - assoc("red","blood") = −0.3
  - assoc("dark-theme","coding") = +0.2
  - assoc("lofi","coding") = +0.2
  - assoc("fps","energetic") = +0.25 (tag-style bridge)
*/
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 6) TIER MAPPING (UI view)
// ---------------------------------------------------------------------------
/*
Absolute thresholds (with hysteresis=0.05):
  Favorite ≥ 0.90
  Love it ≥ 0.60
  Like it ≥ 0.20
  Neutral (−0.20..0.20)
  Dislike ≤ −0.20
  Hate it ≤ −0.60
  Least favorite ≤ −0.90
Quantile policy: when frame ≥12 members, convert to 5–7 buckets by percentile,
apply hysteresis to avoid churn.
*/
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 7) RATING & EVOLUTION HOOKS (cheap to wire now)
// ---------------------------------------------------------------------------
/*
Rater prompts (when EVI>0.5, rapport>0.5, and unsolicited budget open):
  - “Gut check: red vs blue today?”  → map to explicit ∈ [-1..1]
  - “Top 3 focus tracks lately?”     → mark chosen; boost exposures
ExposureTracker: increment exposures when items appear (seen in chat/tool/UI).
AssociationMapper: low-rate Hebbian updates for co-occurring tags/items.
Daily drift: light plasticity on feature_weights & base_score (see main spec).
*/
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 8) PSEUDOCODE (compact; deterministic; comment-ready)
// ---------------------------------------------------------------------------
/*
function GenerateTasteSeed(seed, K=24):
  rng ← PRNG(seed)
  TasteDNA.seed = seed
  TasteDNA.latent_vec = Normalize( RandNormal(K, rng) )
  TasteDNA.temp = 0.10
  TasteDNA.plasticity = 0.04

  // Build tag embeddings
  for tag in TAG_VOCAB:
    v = RandNormal(K, rng_for(tag, seed))
    v += AxisBumps(tag)     // warm/cool, cozy/sleek, etc.
    TAG_EMB[tag] = Normalize(v)

  // Init items
  for item in ITEMS:
    centroid = Normalize( mean( TAG_EMB[t] for t in item.tags ) )
    b = BiasForKind(item.kind)   // small per-kind bias
    eps = RandNormal(1, rng)*0.05
    item.base_score = clamp( tanh( dot(TasteDNA.latent_vec, centroid) + b + eps ), -1, 1 )
    item.stats = {exposures:0, chosen:0, skipped:0}
    register(item)

  // Seed associations (sparse)
  ASSOC["color:red"]["concept:blood"] = -0.3
  ASSOC["ui:dark-theme"]["activity:coding"] = +0.2
  ASSOC["music:lofi"]["activity:coding"] = +0.2

  // Create frames with policies
  for name in FRAMES:
    create_frame(name, policy="absolute", hysteresis=0.05)

  persist(TasteDNA, TAG_EMB, Items, Frames)
  return OK
*/
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// 9) HOW DECISION USES THIS (one line reminder)
// ---------------------------------------------------------------------------
// In the Utility scorer, add PreferenceGain = max(0, S*(candidate,ctx)) with wP=0.20,
// and allow TierAssigner to phrase outputs (“top-tier favorite” vs raw numbers).
// ============================================================================

