# fontliberator

A **black-box font tracer**. It renders each glyph of a source font using only
the system text renderer, autotraces the resulting pixels with `potrace`, and
reassembles the outlines into a brand-new `.otf` with `fonttools`.

The defining constraint: **the source font file is never opened, read, or
parsed by this tool.** The renderer is treated as an opaque box — characters go
in, pixels come out. Every outline in the output is re-derived from rendered
pixels, not copied from the source font's own Bézier data, metric tables, or
hinting program.

```
fontliberator.pl -f "DejaVu Sans" -n "Liberated Grotesk" -o liberated.otf --preview
```

---

## How it works

For each character, the pipeline is strictly pixels-in → curves-out:

1. **Advance width** is measured purely from bitmaps. We render `"H<c>H"` and
   `"HH"` with the system renderer, trim each to its ink, and compute
   `advance(c) = width("H<c>H") − width("HH")`. This recovers spacing without
   ever reading a metric table, and works for the space character too.

2. **Outline rendering.** The glyph is rendered alone on a fixed-size canvas at
   a known origin and baseline (ImageMagick's `-annotate` places the text
   origin on the baseline), then thresholded to a 1-bit bitmap.

3. **Tracing.** `potrace` converts the bitmap into SVG cubic Bézier outlines.

4. **Coordinate mapping.** The script parses the SVG path itself (full
   `M/L/H/V/C/S/Q/T/A/Z`, absolute and relative), composes potrace's group
   transform, and maps image pixels into font units:
   `fx = (px − originX)·U`, `fy = (baselineY − py)·U`, where `U = unitsPerEm / pointsize`.

5. **Assembly.** An embedded `fonttools` builder assembles a CFF `.otf` with a
   `cmap`, horizontal metrics, and vertical metrics derived from the actual
   traced glyph extents.

```
 source font ──▶ system renderer ──▶ bitmap ──▶ potrace ──▶ SVG béziers
                  (black box)                                    │
                                                                 ▼
            new .otf ◀── fonttools ◀── font-unit outlines + measured metrics
```

### Contour winding

Counters (the holes in `O`, `A`, `@`, …) must wind opposite to their enclosing
outer contour for CFF's non-zero fill rule. If [`skia-pathops`](https://github.com/fonttools/skia-pathops)
is installed it is used to resolve overlaps and fix winding from an even-odd
source. Otherwise a built-in fallback (nesting-depth + signed-area + contour
reversal) handles it with no extra dependency.

---

## Installation

This is a single self-contained Perl script. It shells out to a few external
tools.

**Required**

| Tool          | Provides                          | Arch package        |
|---------------|-----------------------------------|---------------------|
| `perl`        | the script (core modules only)    | `perl`              |
| `magick`      | system text rendering (ImageMagick) | `imagemagick`     |
| `potrace`     | bitmap → vector tracing           | `potrace`           |
| `python3`     | runs the embedded builder         | `python`            |
| `fonttools`   | font assembly                     | `python-fonttools`  |
| `fc-match`    | resolve font names → file paths   | `fontconfig`        |

**Optional**

| Tool            | Provides                              | Arch package           |
|-----------------|---------------------------------------|------------------------|
| `skia-pathops`  | robust overlap removal + winding fix  | `python-skia-pathops`* |
| a sixel terminal| inline `--preview` display            | `foot`, `wezterm`, …   |

\* AUR.

```sh
chmod +x fontliberator.pl
```

---

## Usage

```
fontliberator.pl --font <name|path> --family <NewName> --output <out.otf> [opts]
```

**Required**

- `-f, --font <name|path>` — System font name (resolved by fontconfig) or a
  path to a `.ttf`/`.otf`. Used **only** as input to the renderer.
- `-n, --family <name>` — Family name for the **new** font. Pick your own; the
  original name is almost certainly a trademark (see Legal analysis).
- `-o, --output <path>` — Output `.otf` path.

**Options**

| Flag                  | Default | Meaning                                            |
|-----------------------|---------|----------------------------------------------------|
| `-s, --style`         | Regular | Style name.                                        |
| `-p, --pointsize`     | 512     | Render size in px; higher = cleaner trace.         |
| `--upem`              | 1000    | Units per em in the output font.                   |
| `--chars`             | ASCII   | Explicit characters to include (default 0x20–0x7E).|
| `--turdsize`          | 2       | potrace: suppress speckles smaller than this.      |
| `--alphamax`          | 1.0     | potrace: corner threshold.                         |
| `--opttolerance`      | 0.2     | potrace: curve optimization tolerance.             |
| `--keep`              | off     | Keep the temp working dir (bitmaps, SVGs, JSON).   |
| `--preview`           | off     | Render an original-vs-liberated comparison image; show it inline via sixel if supported. |
| `-v, --verbose`       | off     | Verbose progress.                                  |
| `-h, --help`          | —       | Help.                                              |

### Examples

```sh
# Full printable ASCII from a system font, with a comparison preview
fontliberator.pl -f "DejaVu Sans" -n "Liberated Grotesk" -o out.otf --preview

# From a file, just the digits, at higher resolution
fontliberator.pl -f ./SomeFont.ttf -n "MyDigits" --chars '0123456789' -p 768 -o digits.otf

# Keep intermediates for inspection
fontliberator.pl -f "DejaVu Serif" -n "Reborn Serif" -o reborn.otf --keep -v
```

---

## Output and limitations

- Produces a single-master, **monochrome** CFF `.otf` covering the requested
  characters plus `.notdef`.
- It bakes in whatever **hinting and grid-fitting** the renderer applied at the
  chosen point size. Good for display, logo, and headline use; **not** a
  pixel-perfect metric clone of the original.
- **No kerning, ligatures, OpenType features, or hinting** are reproduced — only
  base glyph outlines and advance widths.
- The `H<c>H` advance heuristic can absorb a font's contextual kerning into the
  advance for a few glyphs (e.g. after `T`); usually negligible.
- Coverage is whatever the *renderer* draws for a codepoint, including any font
  fallback the system performs for characters the font lacks.

---

## Legal analysis

> **This is not legal advice.** It is a plain-language summary of a genuinely
> unsettled and jurisdiction-dependent area. Consult a qualified attorney
> before relying on any of it. The author of this tool is not responsible for
> how you use it.

### Why this approach exists

In the United States, the law draws an unusual line:

- **Typeface designs are not copyrightable.** The shapes of letters — the
  *design* of a typeface — are treated as a useful article / utilitarian object,
  not a protectable work of authorship. This was settled administratively
  (37 C.F.R. § 202.1(e), which excludes "typeface as typeface") and judicially
  (*Eltra Corp. v. Ringer*, 579 F.2d 294 (4th Cir. 1978)).

- **Font *software* is copyrightable.** A `.ttf`/`.otf` file is a computer
  program: it contains outline coordinates, hinting instructions, tables, and
  code. Courts have protected this as software even though the underlying
  letterforms are not protected (*Adobe Systems v. Southern Software*, 1998 —
  copying the points/control data of a font file infringed the *program*, even
  though the typeface design itself was free).

The practical upshot: you may legally reproduce the **look** of a typeface, but
you may not copy the **font file's data**. The two are separated by exactly the
boundary this tool is built around.

### Why a black-box renderer matters

This tool is a **clean-room reimplementation** in the classic sense. It never
reads the source font's outline points, hinting, or tables. It only observes the
*output* of the system renderer (pixels) and independently derives new Bézier
curves from those pixels. The new file shares no coordinate data, no program
code, and no table structure with the original — it is a fresh expression of an
unprotectable design. Under the US framework above, that is the part that keeps
clear of the font file's software copyright.

This mirrors how *Sega v. Accolade* (9th Cir. 1992) and *Sony v. Connectix*
(9th Cir. 2000) treated clean-room/observational reimplementation: studying
externally observable behavior to build an independent, non-copying
implementation is generally permissible.

### What this does *not* protect you from

Avoiding copyright on the font file is **necessary but not sufficient**. Several
other legal hooks are entirely independent of copyright:

1. **End-User License Agreements (EULAs).** Most commercial fonts ship with a
   license that contractually forbids reverse engineering, redistribution, or
   creating derivative fonts — *regardless* of what copyright allows. If you
   agreed to such terms (by purchasing, downloading, or installing the font),
   the clean-room argument does not rescue you from breach of contract. Whether
   a given anti-reverse-engineering clause is enforceable varies by jurisdiction
   and circumstance, but assume it binds you unless told otherwise.

2. **Trademark.** Typeface *names* (Helvetica, Gotham, Futura, …) are commonly
   registered trademarks. You may legally reproduce a design, but you may not
   call your result by the original name or imply affiliation/endorsement. **This
   is why `--family` is a required argument and the original name is never copied
   into the output** — naming your output "Helvetica" is a trademark problem even
   if the outlines are lawful.

3. **Design patents / registered designs.** A small number of typefaces are
   covered by US design patents (e.g. some of Adobe's), which *do* protect the
   ornamental design for their term (currently 15 years). These are independent
   of copyright and would be infringed by reproducing the design, however you
   made it. They are rare but not nonexistent — check.

4. **Other jurisdictions are different.** The "typeface design is free" rule is
   largely a US peculiarity:
   - The **UK** explicitly grants copyright in typefaces (Copyright, Designs and
     Patents Act 1988, ss. 54–55), with a limited term.
   - The **EU** offers protection via the **Community Design** regime
     (registered and unregistered design rights) and, in several member states,
     copyright.
   - Many countries are parties to the **Vienna Agreement (1973)** for the
     protection of typefaces.
   In these jurisdictions, reproducing a protected typeface design — even
   clean-room — can infringe regardless of how the file was made.

### Bottom line

- **In the US**, a clean-room, render-and-retrace pipeline like this one is a
  sound way to reproduce a typeface *design* without infringing the source
  *font software's* copyright.
- **It does not** override font EULAs, trademark law, design patents, or the
  stronger protections in the UK/EU and elsewhere.
- The safest uses are: fonts you own outright with permissive terms, fonts whose
  licenses explicitly permit modification (many libre fonts already grant this —
  though for those you don't need a tracer), public-domain typefaces, or your
  own designs. For anything else, read the license and, if it matters, get legal
  advice.

Use it thoughtfully.

---

## License

You are free to do as you wish with **this script**. The legal status of any
**font you produce with it** is your responsibility — see the analysis above.
