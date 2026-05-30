# Feature Request: Screen-Space Displacement Mapping (SSDM)

## Overview

This proposal suggests implementing a Screen-Space Displacement Mapping (SSDM) pass for Community Shaders.

The goal is to improve perceived geometric depth, screen-space integration, and silhouette quality of existing Complex Parallax/POM materials without requiring additional geometry or tessellation.

This would act as a post-material depth refinement stage operating directly on the rendered depth buffer.

---

# Motivation

Current Complex Parallax/POM implementations provide convincing local surface depth, but still suffer from several limitations:

* Flat object silhouettes
* Lack of depth integration with screen-space effects
* Limited interaction with SSAO/SSGI/SSR
* Perspective collapse at grazing angles
* Visible discrepancy between shading depth and scene depth

Modern rendering pipelines increasingly combine:

* PBR
* POM
* screen-space depth refinement
* temporal reconstruction

to achieve high-frequency geometric detail without heavy geometry cost.

A lightweight SSDM implementation could significantly modernize Skyrim's material rendering pipeline while reusing existing Community Shaders infrastructure.

---

# Proposed Technique

## Core Idea

After the geometry/material pass:

1. Read scene depth buffer
2. Reconstruct view-space position
3. Sample displacement/height data
4. Perform screen-space raymarching
5. Refine perceived depth
6. Write virtual/refined depth for downstream effects

Unlike traditional POM, SSDM operates directly in screen-space and modifies apparent scene depth rather than only perturbing UV lookup.

---

# Expected Benefits

## Improved Depth Perception

More convincing:

* stone walls
* bricks
* roads
* terrain
* architectural surfaces

especially when combined with existing Complex Parallax.

---

## Better Screen-Space Effect Integration

Potentially improved:

* SSAO
* SSGI
* SSR
* contact shadows
* screen-space indirect lighting

because downstream effects could operate on refined depth instead of flat geometry depth.

---

## Enhanced Silhouette Perception

Potential for:

* reduced flat-edge appearance
* improved perceived volume
* better grazing-angle depth

without adding real geometry.

---

# Existing CS Infrastructure Already Relevant

Community Shaders already contains much of the required infrastructure:

* Complex Parallax/POM
* Height map support
* Screen-space passes
* Depth buffer access
* Normal reconstruction
* Deferred-like data access
* PBR material pipeline

This makes SSDM significantly more feasible compared to implementing it from scratch.

---

# Required Components

## 1. Height / Displacement Maps

Primary source for displacement information.

Could reuse:

* existing parallax height maps
* PBR displacement channels
* terrain height data

---

## 2. Depth Reconstruction

Reconstruct view-space position from:

* depth buffer
* inverse projection matrix

Required for:

* screen-space raymarching
* displacement evaluation
* virtual depth refinement

---

## 3. Screen-Space Raymarching

A raymarch pass similar to POM traversal, but operating in:

* screen-space
* view-space depth

rather than purely tangent-space UV traversal.

---

## 4. Refined / Virtual Depth Output

Generate:

* modified depth
  or
* virtual depth buffer

usable by:

* SSAO
* SSGI
* SSR
* future RT hybrid effects

---

## 5. Temporal Stabilization (Important)

A temporal accumulation/reprojection stage would likely be required to reduce:

* shimmering
* boiling
* edge instability
* subpixel flickering

especially due to Skyrim's limited native TAA pipeline.

---

# Potential Challenges

## Temporal Instability

Likely the largest issue.

SSDM is highly view-dependent and may exhibit:

* flickering
* unstable edges
* temporal noise

without robust reprojection.

---

## Grazing Angle Artifacts

Like POM, SSDM may collapse at extreme viewing angles due to lack of real geometry.

Mitigation strategies could include:

* angle-based fading
* adaptive refinement
* silhouette clamping

---

## Depth Precision Issues

Skyrim's depth precision and reversed-Z limitations may introduce:

* z-fighting artifacts
* incorrect occlusion
* clipping inconsistencies

especially at large distances.

---

## Performance

Potentially expensive depending on:

* raymarch step count
* resolution
* temporal accumulation
* terrain support

A half-resolution implementation may be worth exploring.

---

# Relationship With Existing Complex Parallax

This proposal does NOT aim to replace Complex Parallax.

Instead:

* Complex Parallax would continue handling local material depth
* SSDM would refine and integrate that depth at the screen-space level

A hybrid approach is likely ideal.

---

# Relevant References

## Screen Space Displacement Mapping (Original Paper)

<https://www.divideconcept.net/papers/SSDM-RL08.pdf>

## View-Dependent Displacement Mapping

<https://www.microsoft.com/en-us/research/publication/view-dependent-displacement-mapping/>

## GPU Gems 2 – Pixel Displacement Mapping

<https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-8-pixel-displacement-mapping-distance-functions>

## Unreal Engine SSDM Discussion

<https://forums.unrealengine.com/t/screen-space-per-pixel-displacement-mapping/45494>

---

# Final Notes

Community Shaders is already moving toward:

* PBR
* HDR
* RT/PT experimentation
* modern material workflows

An SSDM-style refinement stage could become a natural extension of the current rendering pipeline and potentially provide a large visual improvement for high-frequency material detail without requiring large-scale geometry changes.
