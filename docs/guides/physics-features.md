---
sidebar_position: 2
---

# How Sound Propagates

There's a version of sound detection that technically works — any listener within a radius detects any sound, regardless of what's between them and the source — but doesn't feel right. A gunshot behind three concrete walls reads the same as one fired in an open field. A crouching player's footstep is just as detectable as a sprint at the same distance. Detection feels arbitrary in ways that feel unfair.

The gap between "technically works" and "feels like hearing" is propagation physics. Resonix models two things: how sound energy falls off with distance, and how much of what's left is absorbed by the geometry in between.

---

## Stage 1: Distance Falloff

The first thing sound does as it leaves its source is spread. The same total energy is distributed across an ever-larger surface area as the wave expands — so the amount reaching any single point falls off as the square of the distance. Resonix uses a normalized form of this:

```
intensity(d) = I₀ × (1 - (d / R)²)
```

Where `I₀` is source intensity, `d` is distance, and `R` is the emission's configured radius. This gives:
- Full source intensity at the origin (`d = 0`)
- Zero intensity exactly at the radius boundary (`d = R`)
- A smooth, physically-motivated curve in between

This stage is O(1) — no raycasts, no geometry queries. It runs for every emission on every query.

---

## Stage 2: Geometric Occlusion

Once falloff is computed, Resonix checks whether there's geometry between the source and the listener. The result is a **transmission factor** between 0 and 1 that multiplies the post-falloff intensity:

```
effectiveIntensity = falloffIntensity × transmissionFactor
```

A transmission of `1.0` means a completely clear path — every bit of the falloff intensity reaches the listener. A transmission of `0.3` means 70% was absorbed by intervening geometry. The effective intensity approaches zero as more geometry accumulates between source and listener, but — by the mathematics of exponential decay — **never reaches exactly zero**. There is always some acoustic connection between any two points. This feels fair.

---

## Beer-Lambert Absorption

Resonix uses the Beer-Lambert law for occlusion — the same model used in optics and radiation physics for absorption through layered media:

```
transmission = e^(-Σ absorption)
```

Where the sum accumulates absorption coefficients as the ray passes through successive wall segments. Each segment contributes `thickness × material_coefficient` to the total. The exponential function is what gives you the "never fully blocked" property — and it means two half-blocking walls transmit `0.5 × 0.5 = 0.25`, not zero.

---

## Frequency-Dependent Absorption

The most physically significant detail in Resonix's material model: high-frequency sounds are absorbed far more aggressively than low-frequency ones.

This matches physical reality. Dense materials like concrete act as excellent absorbers of short-wavelength (high-frequency) energy but are largely transparent to long-wavelength (low-frequency) pressure waves. A concrete wall that reduces a gunshot crack to near-inaudibility barely dents the pressure wave of an explosion.

The `ABSORPTION` table in `SoundPropagator` encodes this per material:

| Material | Low (explosion) | Mid (voice) | High (gunshot crack) |
|----------|:-:|:-:|:-:|
| Concrete | 0.18 | 0.42 | 0.62 |
| Brick | 0.16 | 0.38 | 0.55 |
| Wood | 0.08 | 0.18 | 0.28 |
| Metal | 0.12 | 0.28 | 0.42 |
| Glass | 0.02 | 0.04 | 0.06 |
| SmoothPlastic | 0.06 | 0.16 | 0.24 |
| WoodPlanks | 0.09 | 0.20 | 0.30 |
| Cobblestone | 0.14 | 0.32 | 0.48 |
| Slate | 0.15 | 0.35 | 0.50 |
| DiamondPlate | 0.10 | 0.22 | 0.35 |
| Fabric | 0.20 | 0.35 | 0.45 |
| Grass | 0.05 | 0.10 | 0.15 |
| Sand | 0.08 | 0.18 | 0.25 |

Units are absorption per stud of material thickness. Any material not in the table uses the default coefficients `{ low: 0.10, mid: 0.22, high: 0.35 }`.

The practical gameplay consequence: a sniper round (High frequency) fired from behind a concrete wall is nearly undetectable, while a grenade explosion (Low frequency) behind the same wall bleeds through clearly. This is emergent from the material table — no per-sound rules, no special cases.

---

## Three Accuracy Tiers

Occlusion is the expensive part of a query — it involves raycasts. Resonix automatically selects one of three accuracy tiers based on how far the listener is from the emission source:

**Full** (listener within 50% of the emission's radius)

A multi-segment ray march through all geometry along the path. Up to 6 segments, with the thickness of each measured using a two-ray technique that correctly handles concave geometry. Per-material, per-frequency absorption applied at each segment. This is the most accurate and most expensive tier.

**Simple** (listener between 50–100% of the emission's radius)

A single raycast. If it hits something, a fixed conservative attenuation factor (`0.35` multiplier) is applied. No material lookup, no thickness measurement. Fast enough to run for every mid-range listener every tick.

**Skip** (listener at or beyond 100% of radius, or per-query budget exceeded)

Returns a transmission of `1.0` — no occlusion check at all. The distance falloff calculation has already handled the intensity at this range, and occlusion would have minimal effect on an already-attenuated signal.

Resonix also enforces a **per-query raycast budget** (`MAX_OCCLUSION_PER_QUERY = 16` by default). If a query encounters more than 16 emissions that would normally use Full or Simple accuracy, the excess emissions are downgraded to Skip. This bounds the worst-case raycast count to `16 × 7 = 112` raycasts per `QueryPosition` call regardless of how many emissions are active.

---

## Thickness Measurement

For Full accuracy, Resonix measures the thickness of each intersected geometry piece using a two-ray technique:

1. The forward ray hits a geometry surface at the entry point.
2. A backward ray is fired from `maxThickness` studs ahead, back toward the entry point.
3. The distance from the backward ray's hit to the entry point is the measured thickness.

This backward-ray approach correctly handles concave geometry that a single forward ray would traverse multiple times — a hollow cylinder, an archway, or any part where the ray could enter, exit, and re-enter the same instance.

---

## What This Means for Gameplay

A game with realistic acoustic propagation gives listeners information that is physically motivated rather than arbitrary:

- A crouching player behind a fabric partition is harder to hear than one standing in an open corridor — not because of a "stealth multiplier" rule, but because fabric absorbs mid-frequency sound effectively.
- An explosion on the other side of a thin wooden wall is clearly detectable; the same explosion behind several layers of concrete is barely audible.
- A vending machine hum (Mid frequency, moderate intensity) falls off quickly in open space but is barely muffled by the thin walls of a utility closet.

No special "hearing range" tuning per-map is needed. The physics handles it.
