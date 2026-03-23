---
sidebar_position: 1
---

# The Polling Gap

You fire a gunshot. No reaction. You fire another — it reacts immediately. A third — nothing again.

It seems random. It isn't.

The problem is a fundamental mismatch between how sound events happen and how polling systems observe them.

---

## The Polling Gap

A polling system doesn't run continuously. It runs on an interval — typically every 0.1 to 0.2 seconds — to keep CPU cost predictable. That's a reasonable design. But sound events happen at arbitrary moments in continuous time.

A gunshot with a 0.05-second physical duration is "live" for less than a single query tick. If the tick runs at `t = 0.00` and the gunshot fires at `t = 0.01`, the next tick at `t = 0.10` will catch it. But if the gunshot fires at `t = 0.09`, the tick at `t = 0.10` is only `0.01` seconds after the shot — and depending on how you wrote the check, it might not be live anymore. The next tick is at `t = 0.20`, well after the shot has ended.

The event was missed. Not because the logic was wrong, but because the timing didn't line up.

---

## The Naive Fix and Why It Doesn't Hold

The obvious response is to keep a list of "recent sounds" and include sounds from the last `N` seconds in every check. This works until you think carefully about what it implies.

If `N = 1.0`, you're treating a gunshot fired one second ago as just as salient as one fired now. You get reactions to stale information — hunting toward a position the player left a second ago, or reacting to a sound that happened long before the query ran.

If `N = 0.1`, you're back to the polling gap problem for any sound shorter than 0.1 seconds.

The correct question isn't "did this sound happen recently?" It's "is this sound *currently relevant* to a listener who happened to poll right now?"

---

## Resonix's Answer: The Relevance Window

Every emission in Resonix has a `Duration` — the physical length of the sound event — and an `ExpiresAt` timestamp:

```
ExpiresAt = EmittedAt + Duration + DECAY_WINDOW (0.6s)
```

A gunshot with a 0.05-second duration stays in the buffer for **0.65 seconds** total. That's enough time for **six consecutive query ticks** at 0.1-second intervals to all detect it.

The decay window is not about memory — it's about ensuring that every polling consumer gets at least one clean observation of every emission, regardless of when relative to the emission they happened to poll. A sound that happened between two ticks will still be present for the next tick. And the one after that, with headroom to spare.

---

## What This Means in Practice

You don't need to worry about polling timing. Emit the sound when it happens, query when your loop ticks.

```lua
-- Fires when the player pulls the trigger — doesn't care when the query runs
Engine:EmitPreset("Gunshot_Rifle", character.HumanoidRootPart.Position, character)

-- Query loop — doesn't care when the gunshot fired
local function QueryTick(listenerPos)
    local stimuli = Engine:QueryPosition(listenerPos, 5)
    for _, stimulus in stimuli do
        ReactToSound(stimulus)
    end
end

RunService.Heartbeat:Connect(function()
    for _, listener in activeListeners do
        if listener.QueryTimer > 0.1 then
            QueryTick(listener.Root.Position)
            listener.QueryTimer = 0
        end
        listener.QueryTimer += RunService.Heartbeat:Wait()
    end
end)
```

The emit call and the query call are completely decoupled. Any sound fired in the last 0.65 seconds (for a gunshot) is visible to any query that runs during that window.

---

## Long-Duration Sounds

The same buffer handles ambient, persistent sounds cleanly. A vending machine with `Duration = 60.0` expires at `EmittedAt + 60.6` seconds. It's present in every query for its full configured lifetime. Cancel it with `:Cancel(emissionId)` when the interaction ends — the emission disappears from all future queries immediately.

---

## Buffer Capacity

The buffer holds up to 128 simultaneous emissions. Beyond that, the oldest emission is evicted to make room. A game with dozens of footsteps, weapon fire, impacts, and environment sounds has headroom to spare within that budget. If you're hitting the cap, look for emissions that should have been cancelled but weren't.
