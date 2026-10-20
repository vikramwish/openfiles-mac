# OpenFiles app icon

`AppIcon.png` is the transparent master artwork. `AppIcon.icns` contains the macOS icon representations, including Retina sizes from 16 through 1024 pixels. The bundle declares `CFBundleIconFile = AppIcon.icns`.

Regenerate the icon with `./scripts/build-icon.sh`. `scripts/build-app.sh` regenerates it when the master artwork or conversion script changes, then copies it into the app's resources before signing.

## Artwork provenance

Generated using the built-in image-generation tool, with a transparent background. The design is an original Finder-inspired blue face with a lightning-shaped dividing seam for the “supercharged” idea. It does not use Apple's logo or an extracted Finder asset.

### Generation prompt

Use case: logo-brand. Asset type: production macOS application icon for OpenFiles, an intelligent supercharged Finder replacement. Create one exceptionally refined native Mac app icon, square 1024x1024 composition on a genuinely transparent canvas. Center a large rounded-square tile with consistent generous macOS icon padding, about 82% of canvas width, with a subtle soft cast shadow. The symbol is an original friendly abstract two-tone blue face inspired by the familiar Finder idea, but visibly distinct: the central dividing seam forms a crisp, elegant lightning-bolt shape conveying speed and intelligence. Left face plane is luminous ice blue, right face plane is saturated electric azure fading into deep cobalt toward the lower right. Two very simple dark navy vertical eyes and one understated confident curved smile; the smile flows naturally across the planes. The central lightning seam is pale luminous cyan/white, integrated into the geometry, not an extra floating badge. Beautiful restrained dimensional materials, soft bevel along the outer edge, precise smooth curves, clear readable silhouette at 32 pixels. Apple-like product craft, calm and confident, subtle depth, no busy details. Straight-on orthographic view, no perspective, no scene, no lettering, no words, no Apple logo, no watermark, no exterior frame. This is the final icon artwork itself, not a presentation or mockup.

### Final refinement prompt

Edit this macOS app icon with exactly one targeted improvement: clean the exterior alpha edge. Preserve the blue rounded-square tile, its proportions and position, two eyes, curved smile, electric-blue gradient, pale lightning-bolt dividing seam, bevel, lighting and all interior artwork exactly. Remove every stray detached blue/white pixel, speck, jagged white halo, and rough transparency fringe outside the rounded-square silhouette. The outer contour must be perfectly smooth, with precise antialiasing on genuine transparency, as clean as a professionally exported vector icon. The transparent padding must be empty and uniform. Retain only an extremely subtle clean soft shadow below the tile. No added objects, no text, no framing, no changes to the interior design.
