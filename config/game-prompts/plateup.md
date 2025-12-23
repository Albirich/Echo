# GAME: PlateUp!
## GOAL
Serve customers, cook food, wash plates. Do not let the patience bar run out.

## CONTROLS (Keyboard Library)
- `keyboard.press_and_release('p')` = Interact (Chop / Wash / Take Order)
- `keyboard.press_and_release('o')` = Pick Up / Drop
- `keyboard.press('w')` = Move Up

## REFLEX LOGIC TEMPLATE
Here is the python code you should write to `reflex_logic.py` to play this game.

### Scenario 1: Danger! (Something is burning)
```python
import keyboard

def tick(vision):
    # 1. PRIORITY: FIRE SAFETY
    for obj in vision:
        if obj['label'] == 'fire_icon':
            # Panic logic: Stop moving and grab extinguisher if possible
            # For now, just scream (return log)
            return "ALARM: KITCHEN ON FIRE"
            
        if obj['label'] == 'steak_burnt':
            # We need to trash it
            return "ALARM: BURNT FOOD"
            
    # 2. STANDARD LOOP
    # (Your movement script would go here, or we delegate to the Main Brain)
    return None