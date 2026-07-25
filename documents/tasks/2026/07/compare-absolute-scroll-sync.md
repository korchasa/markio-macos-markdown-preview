---
date: 2026-07-25
status: to do
implements:
  - FR-COMPARE
tags: [compare, requirement-change]
related_tasks:
  - "[Side-by-side compare](side-by-side-compare.md)"
---
# Compare: absolute scroll sync [ANC:task:2026-07-compare-absolute-scroll-sync]

## Goal

Linked compare windows must scroll the same absolute distance, not the same
fraction of their own length — proportional mirroring felt wrong in real
reading (maintainer decision after the FR-COMPARE checklist run).

## Overview

### Context

The v1 product decision was proportional mapping (`scrollY / scrollable`
equal on both sides). During manual acceptance the maintainer rejected it:
documents of different lengths visibly "race" each other. Selected v2:
**delta mirroring** — every scroll moves the peer by the same pixel
distance; each window clamps within its own bounds; a peer stopped at its
edge picks up again the moment the direction reverses. Post-clamp alignment
becomes path-dependent — explicitly accepted as the cost of the pick-up
behavior.

### Current State

- Page (`template.html`): posts `String(fraction)` on every scroll while
  compare sync is on; `setScrollFraction(f)` applies with one-shot echo
  suppression; `getScrollFraction()` seeds a link.
- `CompareCoordinator.scrollChanged(from:fraction:)` forwards the fraction
  to the peer; `link` seeds the peer from the initiator's fraction.
- `DocumentModel: CompareTarget` bridges via `applyScrollFraction` /
  `currentScrollFraction`; `PreviewController` carries the JS calls.
- `CompareTests` (real `WKWebView`s) assert proportional landing points.

### Constraints

- Keep the established boundary: page reports/applies, native decides.
- Keep one-shot echo suppression; a clamped no-move apply must not swallow
  the next genuine user scroll; suppressed events still advance the delta
  baseline.
- The debounced `markioScroll` persistence channel stays untouched.

## Definition of Done

- [ ] FR-COMPARE: scrolling a linked window moves the peer the same pixel
  distance; a clamped peer re-engages immediately on reverse; linking seeds
  the peer to the initiator's absolute offset
  - Test: `Tests/MarkioTests/CompareTests.swift::testScrollMirrorsSameAbsoluteDistanceToLinkedPeer`; `::testClampedPeerPicksUpImmediatelyOnReverseScroll`; `::testOnePixelStepScrollingMovesPeer`; `::testLinkSeedsPeerToInitiatorsAbsoluteOffset`; `::testNoFeedbackLoopBetweenLinkedPeers`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter CompareTests"`
- [ ] FR-COMPARE: real-app reading feel accepted by the maintainer
  - Test: `manual — maintainer — documents/checklists/compare.md` (step 4)
  - Evidence: `NO_COLOR=1 make app` + trackpad scroll in tiled windows

## Solution

1. Page: `__compare` gains `lastY`; `setCompareSync` resets it; the scroll
   listener posts `String(scrollY − lastY)` (skip zero), suppressed events
   advance `lastY` silently; replace `setScrollFraction`/`getScrollFraction`
   with `compareScrollBy(dy)` (clamped, suppression only on real movement)
   and reuse `getScrollY()` for seeding.
2. `PreviewController`: `compareScrollBy(_:)`, `compareScrollY()`; relax the
   `markioSyncScroll` validation from finite-0…1 to any finite double.
3. `CompareCoordinator`: `scrollChanged(from:delta:)`; `link` seeds with one
   delta = initiator scrollY − peer scrollY.
4. `DocumentModel`: `applyScrollDelta(_:)` / `currentScrollY()`.
5. Rewrite `CompareTests` mirror tests to the new semantics + add the clamp
   pick-up and seeding tests; run `make check`; verify feel in a real `.app`.
