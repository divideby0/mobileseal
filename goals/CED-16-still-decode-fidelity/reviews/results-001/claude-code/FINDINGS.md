# Blind review — CED-16 still-decode fidelity (claude-code)

## Verdict

The fix is correct, minimal, and matches the goal spec. `StillDecoder`
now routes normal images through `kCGImageSourceCreateThumbnailFromImageAlways`
(regenerating from the full-size image at the existing 4096 ceiling)
while RAW/DNG containers keep the `IfAbsent` embedded-preview path,
detected via `UTType.rawImage` conformance with a per-index
RAW/DNG-dictionary fallback. I independently reproduced the decode
behavior against the three committed fixtures: the 6000×4000 embedded-
thumbnail HEIC now decodes to 4096×2730 (was 432×288), the 1200×800
HEIC decodes native, and the synthetic DNG classifies as
`com.adobe.raw-image` and routes to the preview path — so every
assertion in `StillDecoderTests` holds. Scope item 2 (purge cached
decoded stills on upgrade) is satisfied by verification, not code: the
decoded still is written straight to `imageView.image` per page load
and never persisted, and the grid uses a separate small-ceiling
`ThumbnailPipeline.decode`, so nothing carries a stale soft decode
across an upgrade. The UI-test import-count deltas (+2) are internally
consistent with the two new HEICs being picked up by the extension
filter and the `.dng` being excluded. I found one minor memory concern
and no blockers.

## Findings

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | minor | App/MobileSeal/Detail/MediaPageViewController.swift:101 | Full-res decode runs eagerly in `viewDidLoad`, so preloaded neighbor pages each hold a ~44 MB 4096-px still (was ~0.5 MB); 2–3 can be resident at once. |

## Detail

### 1. Full-res still decode runs for off-screen neighbor pages (minor)

**Evidence:** `App/MobileSeal/Detail/MediaPageViewController.swift:101-108`
starts the decode task inside `viewDidLoad`:

```swift
decodeTask = Task { [weak self] in
    if let poster = await self?.store.thumbnails.image(for: target) { ... }
    guard let self, !target.isVideo else { return }
    await self.decodeFullStill()          // <- not gated on didLand
}
```

`decodeFullStill` (line 151) produces a bitmap bounded by
`StillDecoder.maxPixelSize` = 4096. My local ImageIO run confirms an
iPhone-shaped 6000×4000 HEIC now decodes to **4096×2730 ≈ 44 MiB RGBA**,
versus the ~0.5 MiB 432×288 embedded preview the pre-fix `IfAbsent`
path returned. `UIPageViewController` in scroll-transition mode
instantiates the adjacent page view controllers (their `viewDidLoad`
fires) to stage the scroll, so the full-res decode is kicked off for
neighbors that are not the landed page — unlike video/Live-Photo
playback, which is correctly deferred to `didLand` (line 141).

**Why it matters:** With this diff the per-still decoded footprint
jumps ~90×. Two-to-three 4096-px stills can now be resident
simultaneously (~90–130 MiB of decoded bitmaps), on top of the up-to-
256 MiB whole-file `Data` buffer each detached decode allocates
(`decryptWhole`, line 169). The `StillDecoder` doc comment (lines
12–14) justifies the 4096 ceiling as "one on-screen still plus
transition headroom inside any iPhone jetsam budget" — a rationale
written for a single on-screen decode, which the eager neighbor
preload exceeds. This raises jetsam risk on memory-constrained devices,
which the previous tiny-preview behavior masked. It is not a
correctness bug and is within the letter of CED-11's design, so it does
not block; but the memory profile the ceiling comment describes no
longer matches reality.

**Suggested fix (or accept explicitly):** Gate `decodeFullStill()` on
`didLand()` (neighbors keep only the poster thumbnail until they become
the landed page), or decode neighbors at a reduced ceiling and upgrade
to full-res on land. Deferring is defensible given the XS scope and the
explicit "no progressive-zoom work" boundary — in that case, update the
ceiling comment to acknowledge that transition preloading can hold more
than one full-res still at a time so the stated budget isn't misleading.

REVIEW COMPLETE
