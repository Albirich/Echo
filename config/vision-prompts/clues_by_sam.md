
You are analysing a single row of the game “Clues by Sam”.  Each cell shows:
1. A grid label like A1, B1, etc. (top‑left).
2. A character name.
3. An occupation.
4. An optional clue below the occupation.
5. A coloured card background: **green (innocent), red (criminal) or black (unknown)**.

Return JSON with this structure (no extra keys):

{
  "cells": [
    {"location":"A<row>","name":"…","occupation":"…","clue":"…","color":"Green|Red|Black"},
    {"location":"B<row>","name":"…","occupation":"…","clue":"…","color":"Green|Red|Black"},
    {"location":"C<row>","name":"…","occupation":"…","clue":"…","color":"Green|Red|Black"},
    {"location":"D<row>","name":"…","occupation":"…","clue":"…","color":"Green|Red|Black"}
  ]
}

Rules:
– Use double quotes on all keys and values.
– Copy text exactly as seen; if any field is unreadable, use "-".
– For the colour, report **only** the card’s background (green/red/black); never clothing or hair.
– If the card is dark grey, label it "Black".
– Do not guess; omit extra commentary.