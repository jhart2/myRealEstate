# Gallery watermark (fullscreen + download)

## Goal
Soft bottom-right TT Realty brand mark on fullscreen gallery photos and the same mark burned into Download payloads.

## Scope
- Fullscreen viewer overlay only (not thumbs / cards)
- Server-side composite on `GET /properties/:id/photos/:index/download`

## Design
- Placement: bottom-right, padded
- Opacity: ~45%
- Brand: typographic “TT” + “Realty” matching site header
- Viewer: CSS overlay (`pointer-events: none`) on each fullscreen slide
- Download: `GalleryPhotoWatermarker` uses libvips text + composite (no SVG dependency — works in Docker with `libvips`)

## Out of scope
- Watermarking CDN originals in place
- Stopping raw URL grabs via DevTools
