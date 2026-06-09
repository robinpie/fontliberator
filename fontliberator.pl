#!/usr/bin/env perl
#
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 robinpie <robin413@protonmail.com>
#
# fontliberator.pl -- black-box font tracer
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# Renders each glyph of a source font using ONLY the system text renderer
# (ImageMagick + the OS font stack), autotraces the resulting bitmap with
# potrace, and reassembles the outlines into a brand-new .otf with fonttools.
#
# The source font file is NEVER parsed or read by this program. We treat the
# system renderer as an opaque black box: characters go in, pixels come out.
# That is the whole point -- outlines are re-derived from rendered pixels, not
# copied from the source font's own Bezier data.
#
# Pipeline per glyph:
#   1. render "H<c>H" and "HH" as bitmaps, measure trimmed widths  -> advance
#   2. render "<c>" alone on a fixed canvas at a known origin/baseline
#   3. threshold to 1-bit, potrace -> SVG cubic outlines
#   4. parse SVG path, map pixel coords -> font units (y flipped, origin shifted)
#   5. hand the outlines + metrics to an embedded fonttools builder -> .otf
#
# External tools used via subprocess: magick (ImageMagick), potrace, python3
# (with the fonttools package; skia-pathops used if available).

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP;
use Encode qw(decode_utf8 encode_utf8);

# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

my %opt = (
    font       => undef,   # system font name or path to .ttf/.otf
    family     => undef,   # family name for the NEW font
    style      => 'Regular',
    output     => undef,   # output .otf path
    pointsize  => 512,     # render size in px (== em size); higher = cleaner
    upem       => 1000,    # units per em in the output font
    chars      => undef,   # optional explicit string of chars to include
    turdsize   => 2,       # potrace: suppress speckles smaller than this
    alphamax   => 1.0,     # potrace: corner threshold
    opttolerance => 0.2,   # potrace: curve optimization tolerance
    keep       => 0,       # keep the temp working dir for inspection
    preview    => 0,       # render an original-vs-liberated comparison image
    verbose    => 0,
    help       => 0,
);

GetOptions(
    'font|f=s'      => \$opt{font},
    'family|n=s'    => \$opt{family},
    'style|s=s'     => \$opt{style},
    'output|o=s'    => \$opt{output},
    'pointsize|p=i' => \$opt{pointsize},
    'upem=i'        => \$opt{upem},
    'chars=s'       => \$opt{chars},
    'turdsize=i'    => \$opt{turdsize},
    'alphamax=f'    => \$opt{alphamax},
    'opttolerance=f'=> \$opt{opttolerance},
    'keep'          => \$opt{keep},
    'preview'       => \$opt{preview},
    'verbose|v'     => \$opt{verbose},
    'help|h'        => \$opt{help},
) or usage(1);

usage(0) if $opt{help};

unless (defined $opt{font} && defined $opt{family} && defined $opt{output}) {
    print STDERR "error: --font, --family and --output are all required\n\n";
    usage(1);
}

# ----------------------------------------------------------------------------
# Character set: full printable ASCII (0x20..0x7E) unless overridden.
# ----------------------------------------------------------------------------

my @chars;
if (defined $opt{chars}) {
    @chars = split //, decode_utf8($opt{chars});
} else {
    @chars = map { chr } (0x20 .. 0x7E);
}

# ----------------------------------------------------------------------------
# Tool discovery
# ----------------------------------------------------------------------------

my $MAGICK = first_in_path(qw(magick convert))
    or die "error: ImageMagick (magick/convert) not found in PATH\n";
my $POTRACE = first_in_path(qw(potrace))
    or die "error: potrace not found in PATH\n";
my $PYTHON = first_in_path(qw(python3 python))
    or die "error: python3 not found in PATH\n";
my $FCMATCH = first_in_path(qw(fc-match));   # optional name->path resolver

# Resolve the font we hand to the renderer. If the user gave a path, use it as
# is. Otherwise ask fontconfig (the system's own font resolver) to map the
# family name to a file path -- ImageMagick can't always look up family names
# itself. We still never parse the file: it only ever feeds the renderer.
my $RENDER_FONT = $opt{font};
if (!-e $opt{font} && $FCMATCH) {
    my $path = capture($FCMATCH, '-f', '%{file}', $opt{font});
    if (defined $path && length $path && -e $path) {
        vsay("resolved '$opt{font}' -> $path");
        $RENDER_FONT = $path;
        # fontconfig always returns *something*; warn if it substituted a
        # different family than asked for (likely a typo / missing font).
        my $fam = capture($FCMATCH, '-f', '%{family}', $opt{font});
        $fam = '' unless defined $fam;
        $fam =~ s/\s+$//;
        if (index(lc $fam, lc $opt{font}) < 0) {
            print STDERR "warning: '$opt{font}' not found; fontconfig "
                . "substituted '$fam'. Output will trace that instead.\n";
        }
    }
}

# ----------------------------------------------------------------------------
# Render geometry. ImageMagick's -annotate places the text origin at the
# baseline, so we choose a fixed canvas with a known origin (ORIGIN_X) and
# baseline (BASELINE_Y) in pixels. Everything maps back to font units from
# there. y in font space points up; y in pixel space points down.
# ----------------------------------------------------------------------------

my $P         = $opt{pointsize};
my $CANVAS_W  = int($P * 2.0 + 0.5);
my $CANVAS_H  = int($P * 3.0 + 0.5);
my $ORIGIN_X  = int($P * 0.5 + 0.5);
my $BASELINE_Y= int($P * 2.0 + 0.5);
my $UPEM      = $opt{upem};
my $U         = $UPEM / $P;   # pixels -> font units scale factor

my $work = tempdir('fontliberator.XXXXXX', TMPDIR => 1, CLEANUP => !$opt{keep});
vsay("working dir: $work");

# ----------------------------------------------------------------------------
# Main loop: render + trace each glyph.
# ----------------------------------------------------------------------------

my %glyphs;       # char => { advance => units, contours => [...] }
my $ref = 'H';    # inky reference glyph used to bracket advance measurements
my $wHH = trim_width($ref . $ref);   # width of two reference glyphs
die "error: could not measure reference glyph '$ref' with this font.\n"
    . "       check the font name/path is resolvable by ImageMagick.\n"
    if $wHH <= 0;

my $n = 0;
for my $c (@chars) {
    $n++;
    my $cp = ord $c;
    my $label = sprintf "U+%04X %s", $cp, ($cp == 0x20 ? '(space)' : $c);
    vsay(sprintf "[%d/%d] %s", $n, scalar(@chars), $label);

    # --- advance width, measured purely from rendered bitmaps ---------------
    my $wHcH = trim_width($ref . $c . $ref);
    my $adv_px = $wHcH - $wHH;
    $adv_px = 0 if $adv_px < 0;
    my $advance = int($adv_px * $U + 0.5);

    # --- outline: render the glyph alone, then trace ------------------------
    my $contours = trace_glyph($c);

    $glyphs{$c} = { advance => $advance, contours => $contours };
}

# ----------------------------------------------------------------------------
# Hand off to the embedded fonttools builder.
# ----------------------------------------------------------------------------

my $spec = {
    familyName => $opt{family},
    styleName  => $opt{style},
    unitsPerEm => $UPEM,
    glyphs     => {},   # codepoint(string) => {advance, contours}
};
for my $c (@chars) {
    $spec->{glyphs}{ ord($c) } = $glyphs{$c};
}

my $json_path = File::Spec->catfile($work, 'spec.json');
open my $jf, '>', $json_path or die "cannot write $json_path: $!";
print $jf JSON::PP->new->utf8->encode($spec);
close $jf;

my $py_path = File::Spec->catfile($work, 'build_font.py');
open my $pf, '>', $py_path or die "cannot write $py_path: $!";
print $pf python_builder_source();
close $pf;

vsay("assembling OTF with fonttools...");
my @build = ($PYTHON, $py_path, $json_path, $opt{output});
my $rc = system { $build[0] } @build;
die "error: font builder failed (exit @{[ $rc >> 8 ]})\n" if $rc != 0;

print "wrote $opt{output}\n";
print "  family : $opt{family} $opt{style}\n";
print "  glyphs : ", scalar(@chars), " (+ .notdef)\n";
print "  source : $opt{font} (rendered black-box; never parsed)\n";

make_preview(\@chars) if $opt{preview};

exit 0;

# ============================================================================
# Subroutines
# ============================================================================

# Measure the trimmed ink width (in pixels) of a rendered string using the
# system renderer. This is how we recover advance widths without ever looking
# at the font's metric tables: advance(c) = width("HcH") - width("HH").
sub trim_width {
    my ($text) = @_;
    my @cmd = (
        $MAGICK,
        '-background', 'white',
        '-fill',       'black',
        '-font',       $RENDER_FONT,
        '-pointsize',  $P,
        'label:' . escape_annot($text),
        '-bordercolor','white', '-border', '4',
        '-trim',
        '-format',     '%w',
        'info:-',
    );
    my $out = capture(@cmd);
    return -1 unless defined $out;
    $out =~ s/\s+//g;
    return $out =~ /^(\d+)$/ ? $1 : -1;
}

# Render a single glyph on the fixed canvas at the known origin/baseline,
# threshold to bilevel, run potrace, and return contours in font units.
sub trace_glyph {
    my ($c) = @_;

    my $pbm = File::Spec->catfile($work, sprintf("g_%04x.pbm", ord $c));
    my $svg = File::Spec->catfile($work, sprintf("g_%04x.svg", ord $c));

    my @render = (
        $MAGICK,
        '-size', "${CANVAS_W}x${CANVAS_H}", 'xc:white',
        '-font', $RENDER_FONT,
        '-pointsize', $P,
        '-fill', 'black',
        '-annotate', "+${ORIGIN_X}+${BASELINE_Y}", escape_annot($c),
        '-threshold', '50%',
        $pbm,
    );
    run(@render);

    # potrace: black = foreground. Emit SVG cubic outlines.
    my @pt = (
        $POTRACE,
        '--svg',
        '--turdsize', $opt{turdsize},
        '--alphamax', $opt{alphamax},
        '--opttolerance', $opt{opttolerance},
        '-o', $svg,
        $pbm,
    );
    run(@pt);

    return parse_potrace_svg($svg);
}

# ----------------------------------------------------------------------------
# potrace SVG parsing.
#
# potrace emits something like:
#   <svg ... width="WPT" height="HPT" ...>
#     <g transform="translate(0,H) scale(0.1,-0.1)" fill="#000000" ...>
#       <path d="M.. C.. L.. z .."/>
#     </g>
#   </svg>
#
# Path coordinates are in potrace's internal (10x) units; the group transform
# maps them to image pixels. We compose that transform, then map pixels to
# font units: fx = (px - ORIGIN_X)*U,  fy = (BASELINE_Y - py)*U.
# ----------------------------------------------------------------------------

sub parse_potrace_svg {
    my ($svg_path) = @_;
    open my $fh, '<', $svg_path or return [];
    local $/;
    my $svg = <$fh>;
    close $fh;

    # Affine of the enclosing <g> (may be absent -> identity).
    my @M = (1, 0, 0, 1, 0, 0);   # a b c d e f : x'=a*x+c*y+e ; y'=b*x+d*y+f
    if ($svg =~ /<g\b[^>]*\btransform\s*=\s*"([^"]*)"/s) {
        @M = parse_transform($1);
    }

    my @contours;
    # There can be more than one <path>; concatenate their subpaths.
    while ($svg =~ /<path\b[^>]*\bd\s*=\s*"([^"]*)"/sg) {
        push @contours, parse_path_d($1, \@M);
    }
    return \@contours;
}

# Compose an SVG transform string into a single 2x3 affine.
sub parse_transform {
    my ($str) = @_;
    my @M = (1, 0, 0, 1, 0, 0);
    while ($str =~ /(\w+)\s*\(([^)]*)\)/g) {
        my ($fn, $args) = ($1, $2);
        my @a = grep { length } split /[\s,]+/, $args;
        my @T;
        if ($fn eq 'matrix') {
            @T = @a[0..5];
        } elsif ($fn eq 'translate') {
            @T = (1, 0, 0, 1, $a[0] // 0, $a[1] // 0);
        } elsif ($fn eq 'scale') {
            my $sx = $a[0] // 1;
            my $sy = defined $a[1] ? $a[1] : $sx;
            @T = ($sx, 0, 0, $sy, 0, 0);
        } else {
            next;   # ignore rotate/skew; potrace never emits them
        }
        @M = mat_mul(@M, @T);
    }
    return @M;
}

# Compose two affines: result applies B first, then A  (A * B).
sub mat_mul {
    my ($a1,$b1,$c1,$d1,$e1,$f1, $a2,$b2,$c2,$d2,$e2,$f2) = @_;
    return (
        $a1*$a2 + $c1*$b2,            # a
        $b1*$a2 + $d1*$b2,            # b
        $a1*$c2 + $c1*$d2,            # c
        $b1*$c2 + $d1*$d2,            # d
        $a1*$e2 + $c1*$f2 + $e1,      # e
        $b1*$e2 + $d1*$f2 + $f1,      # f
    );
}

# Apply affine + pixel->font-unit mapping to a single point.
sub xform {
    my ($M, $x, $y) = @_;
    my ($a,$b,$c,$d,$e,$f) = @$M;
    my $px = $a*$x + $c*$y + $e;
    my $py = $b*$x + $d*$y + $f;
    my $fx = ($px - $ORIGIN_X) * $U;
    my $fy = ($BASELINE_Y - $py) * $U;
    return ($fx, $fy);
}

# Parse an SVG path "d" string into contours of font-unit drawing commands.
# Each contour is an arrayref of: ["move",x,y] ["line",x,y]
# ["curve",x1,y1,x2,y2,x3,y3] ["close"].
sub parse_path_d {
    my ($d, $M) = @_;

    # Tokenize into command letters and numbers.
    my @tok;
    while ($d =~ /([MmLlHhVvCcSsQqTtAaZz])|([+-]?(?:\d*\.\d+|\d+\.?)(?:[eE][+-]?\d+)?)/g) {
        push @tok, defined $1 ? $1 : $2;
    }

    my @contours;
    my @cur;                 # current contour
    my ($cx, $cy) = (0, 0);  # current point (path units)
    my ($sx, $sy) = (0, 0);  # subpath start (path units)
    my ($pcx, $pcy);         # previous cubic control (for S)
    my ($pqx, $pqy);         # previous quad control  (for T)
    my $cmd = '';
    my $i = 0;

    my $emit_move = sub {
        my ($x, $y) = @_;
        push @contours, [@cur] if @cur;
        @cur = ();
        my ($fx, $fy) = xform($M, $x, $y);
        push @cur, ["move", $fx, $fy];
        ($cx, $cy) = ($x, $y);
        ($sx, $sy) = ($x, $y);
    };
    my $emit_line = sub {
        my ($x, $y) = @_;
        my ($fx, $fy) = xform($M, $x, $y);
        push @cur, ["line", $fx, $fy];
        ($cx, $cy) = ($x, $y);
    };
    my $emit_curve = sub {
        my ($x1,$y1,$x2,$y2,$x3,$y3) = @_;
        my ($f1x,$f1y) = xform($M,$x1,$y1);
        my ($f2x,$f2y) = xform($M,$x2,$y2);
        my ($f3x,$f3y) = xform($M,$x3,$y3);
        push @cur, ["curve",$f1x,$f1y,$f2x,$f2y,$f3x,$f3y];
        ($cx,$cy) = ($x3,$y3);
    };
    my $emit_close = sub {
        push @cur, ["close"];
        ($cx, $cy) = ($sx, $sy);
    };

    my $num = sub { return $tok[$i++]; };

    while ($i < @tok) {
        my $t = $tok[$i];
        if ($t =~ /^[A-Za-z]$/) { $cmd = $t; $i++; }
        # else: implicit repeat of previous command

        my $rel = ($cmd eq lc $cmd);   # lowercase => relative
        my $UC  = uc $cmd;

        if ($UC eq 'M') {
            my $x = $num->(); my $y = $num->();
            ($x, $y) = ($cx + $x, $cy + $y) if $rel;
            $emit_move->($x, $y);
            $cmd = $rel ? 'l' : 'L';     # subsequent pairs are lineto
            undef $pcx; undef $pqx;
        }
        elsif ($UC eq 'L') {
            my $x = $num->(); my $y = $num->();
            ($x, $y) = ($cx + $x, $cy + $y) if $rel;
            $emit_line->($x, $y);
            undef $pcx; undef $pqx;
        }
        elsif ($UC eq 'H') {
            my $x = $num->();
            $x = $cx + $x if $rel;
            $emit_line->($x, $cy);
            undef $pcx; undef $pqx;
        }
        elsif ($UC eq 'V') {
            my $y = $num->();
            $y = $cy + $y if $rel;
            $emit_line->($cx, $y);
            undef $pcx; undef $pqx;
        }
        elsif ($UC eq 'C') {
            my ($x1,$y1,$x2,$y2,$x3,$y3) = ($num->(),$num->(),$num->(),$num->(),$num->(),$num->());
            if ($rel) {
                ($x1,$y1) = ($cx+$x1,$cy+$y1);
                ($x2,$y2) = ($cx+$x2,$cy+$y2);
                ($x3,$y3) = ($cx+$x3,$cy+$y3);
            }
            $emit_curve->($x1,$y1,$x2,$y2,$x3,$y3);
            ($pcx,$pcy) = ($x2,$y2); undef $pqx;
        }
        elsif ($UC eq 'S') {
            my ($x2,$y2,$x3,$y3) = ($num->(),$num->(),$num->(),$num->());
            if ($rel) {
                ($x2,$y2) = ($cx+$x2,$cy+$y2);
                ($x3,$y3) = ($cx+$x3,$cy+$y3);
            }
            my ($x1,$y1) = defined $pcx ? (2*$cx-$pcx, 2*$cy-$pcy) : ($cx,$cy);
            $emit_curve->($x1,$y1,$x2,$y2,$x3,$y3);
            ($pcx,$pcy) = ($x2,$y2); undef $pqx;
        }
        elsif ($UC eq 'Q') {
            my ($qx,$qy,$x3,$y3) = ($num->(),$num->(),$num->(),$num->());
            if ($rel) {
                ($qx,$qy) = ($cx+$qx,$cy+$qy);
                ($x3,$y3) = ($cx+$x3,$cy+$y3);
            }
            # quadratic -> cubic
            my ($x1,$y1) = ($cx + 2/3*($qx-$cx), $cy + 2/3*($qy-$cy));
            my ($x2,$y2) = ($x3 + 2/3*($qx-$x3), $y3 + 2/3*($qy-$y3));
            $emit_curve->($x1,$y1,$x2,$y2,$x3,$y3);
            ($pqx,$pqy) = ($qx,$qy); undef $pcx;
        }
        elsif ($UC eq 'T') {
            my ($x3,$y3) = ($num->(),$num->());
            if ($rel) { ($x3,$y3) = ($cx+$x3,$cy+$y3); }
            my ($qx,$qy) = defined $pqx ? (2*$cx-$pqx, 2*$cy-$pqy) : ($cx,$cy);
            my ($x1,$y1) = ($cx + 2/3*($qx-$cx), $cy + 2/3*($qy-$cy));
            my ($x2,$y2) = ($x3 + 2/3*($qx-$x3), $y3 + 2/3*($qy-$y3));
            $emit_curve->($x1,$y1,$x2,$y2,$x3,$y3);
            ($pqx,$pqy) = ($qx,$qy); undef $pcx;
        }
        elsif ($UC eq 'A') {
            # Arc: not emitted by potrace. Skip its 7 params, line to endpoint.
            my @p = map { $num->() } 1..7;
            my ($x,$y) = ($p[5], $p[6]);
            ($x,$y) = ($cx+$x,$cy+$y) if $rel;
            $emit_line->($x,$y);
            undef $pcx; undef $pqx;
        }
        elsif ($UC eq 'Z') {
            $emit_close->();
            undef $pcx; undef $pqx;
        }
        else {
            $i++;   # unknown token; skip defensively
        }
    }
    push @contours, [@cur] if @cur;

    # Ensure each contour is explicitly closed for the charstring pen.
    for my $ct (@contours) {
        push @$ct, ["close"] unless @$ct && $ct->[-1][0] eq 'close';
    }
    return @contours;
}

# ----------------------------------------------------------------------------
# Preview: render the same characters with the original font and the freshly
# built one, stacked for comparison. Saved next to the output; also shown
# inline via sixel if the terminal supports it.
# ----------------------------------------------------------------------------

sub make_preview {
    my ($chars) = @_;

    # Sample text = the characters we actually traced (so every glyph exists
    # in both fonts). Drop the space at the very front so caption doesn't eat
    # leading whitespace; spacing is still exercised mid-string.
    my $sample = join '', @$chars;
    $sample =~ s/^\s+//;

    my $W  = 1000;
    my $pt = 40;

    my $top   = File::Spec->catfile($work, 'prev_top.png');
    my $bot   = File::Spec->catfile($work, 'prev_bot.png');
    my $ltop  = File::Spec->catfile($work, 'prev_ltop.png');
    my $lbot  = File::Spec->catfile($work, 'prev_lbot.png');

    render_caption_block($RENDER_FONT,   $sample, $pt, $W, $top);
    render_caption_block($opt{output},   $sample, $pt, $W, $bot);
    render_label_block("original  ($opt{font})", $W, $ltop);
    render_label_block("liberated  ($opt{family} $opt{style})", $W, $lbot);

    my $prev = $opt{output};
    $prev =~ s/\.otf$//i;
    $prev .= '.preview.png';

    run($MAGICK, $ltop, $top, $lbot, $bot,
        '-background', 'white', '-append',
        '-bordercolor', 'white', '-border', '12',
        '-bordercolor', '#cccccc', '-border', '1',
        $prev);
    print "  preview: $prev\n";

    if (terminal_supports_sixel()) {
        # Scale to a terminal-friendly size and write sixel to stdout.
        my $rc = system { $MAGICK } $MAGICK, $prev, '-resize', '900x>', 'sixel:-';
        print STDERR "warning: sixel display failed\n" if $rc != 0;
    } else {
        vsay("terminal does not advertise sixel; preview saved to file only");
    }
}

sub render_caption_block {
    my ($font, $text, $pt, $width, $out) = @_;
    run($MAGICK,
        '-background', 'white', '-fill', 'black',
        '-font', $font, '-pointsize', $pt,
        '-size', "${width}x",
        'caption:' . escape_annot($text),
        $out);
}

sub render_label_block {
    my ($text, $width, $out) = @_;
    run($MAGICK,
        '-background', '#f0f0f0', '-fill', '#444444',
        '-pointsize', 16, '-gravity', 'West',
        '-size', "${width}x26",
        'caption:' . escape_annot($text),
        $out);
}

# Detect sixel support by sending a Primary Device Attributes request (ESC [ c)
# and checking whether the terminal lists attribute "4" (sixel graphics).
sub terminal_supports_sixel {
    return 0 unless -t STDOUT;
    return 0 unless open(my $tty, '+<', '/dev/tty');

    my $old = `stty -g </dev/tty 2>/dev/null`;
    chomp $old;
    return 0 unless length $old;

    # Non-canonical, no echo so the reply doesn't print and we can read it raw.
    system("stty -echo -icanon min 0 time 0 </dev/tty 2>/dev/null");

    syswrite($tty, "\e[c");

    my $resp = '';
    for (1 .. 4) {                       # poll up to ~0.8s total
        my $rin = '';
        vec($rin, fileno($tty), 1) = 1;
        my $n = select(my $rout = $rin, undef, undef, 0.2);
        if (defined $n && $n > 0) {
            my $buf = '';
            my $got = sysread($tty, $buf, 256);
            last unless $got;
            $resp .= $buf;
            last if $resp =~ /c/;        # DA reply terminates with 'c'
        } elsif (length $resp) {
            last;
        }
    }

    system("stty $old </dev/tty 2>/dev/null");
    close $tty;

    # Reply looks like: ESC [ ? 64 ; 1 ; 2 ; 4 ; ... c   -- "4" == sixel
    if ($resp =~ /\e\[\?([0-9;]+)c/) {
        return 1 if grep { $_ eq '4' } split /;/, $1;
    }
    return 0;
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# ImageMagick interprets '%' (format escapes) and '\' (control escapes) inside
# annotate/label text. Double them so the literal characters survive. Because
# we exec without a shell, no other quoting is needed.
sub escape_annot {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/%/%%/g;
    return encode_utf8($s);   # exec needs bytes, not wide chars
}

sub run {
    my @cmd = @_;
    vsay("\$ @cmd");
    my $rc = system { $cmd[0] } @cmd;
    die "error: command failed (@{[ $rc>>8 ]}): @cmd\n" if $rc != 0;
}

# Run a command, return stdout (or undef on failure).
sub capture {
    my @cmd = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open STDERR, '>', File::Spec->devnull();
        exec { $cmd[0] } @cmd or exit 127;
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return $? == 0 ? $out : undef;
}

sub first_in_path {
    my @names = @_;
    for my $name (@names) {
        for my $dir (File::Spec->path()) {
            my $p = File::Spec->catfile($dir, $name);
            return $name if -x $p;     # exec by name; relies on PATH
        }
    }
    return undef;
}

sub vsay { print STDERR "@_\n" if $opt{verbose}; }

sub usage {
    my ($code) = @_;
    print STDERR <<'USAGE';
fontliberator.pl -- black-box font tracer

Renders a font with the system text renderer, autotraces the pixels with
potrace, and rebuilds the outlines into a new .otf. The source font file is
never read or parsed; only its rendered output is used.

USAGE:
  fontliberator.pl --font <name|path> --family <NewName> --output <out.otf> [opts]

REQUIRED:
  -f, --font <name|path>   System font name (resolved by ImageMagick) or a
                           path to a .ttf/.otf. Used ONLY as input to the
                           renderer; the file is never parsed by this tool.
  -n, --family <name>      Family name for the NEW font (use your own -- the
                           original name is almost certainly a trademark).
  -o, --output <path>      Output .otf path.

OPTIONS:
  -s, --style <name>       Style name (default: Regular).
  -p, --pointsize <px>     Render size; higher = cleaner trace (default: 512).
      --upem <n>           Units per em in the output (default: 1000).
      --chars <string>     Explicit characters to include (default: printable
                           ASCII 0x20-0x7E).
      --turdsize <n>       potrace speckle suppression (default: 2).
      --alphamax <f>       potrace corner threshold (default: 1.0).
      --opttolerance <f>   potrace curve optimization (default: 0.2).
      --keep               Keep the temp working dir (bitmaps, SVGs, JSON).
      --preview            Render an original-vs-liberated comparison image
                           next to the output; display it inline via sixel if
                           the terminal supports sixel graphics.
  -v, --verbose            Verbose progress.
  -h, --help               This help.

EXAMPLE:
  fontliberator.pl -f "DejaVu Sans" -n "Liberated Grotesk" -o out.otf -v
USAGE
    exit $code;
}

# ============================================================================
# Embedded fonttools builder (Python). Reads spec.json, builds a CFF .otf.
# Handles contour winding for non-zero fill itself, and will additionally use
# skia-pathops to clean overlaps if that package is installed.
# ============================================================================

sub python_builder_source {
    return <<'PYEOF';
#!/usr/bin/env python3
"""Build a CFF .otf from traced outlines produced by fontliberator.pl."""
import json, sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.recordingPen import RecordingPen
try:
    from fontTools.agl import UV2AGL
except Exception:
    UV2AGL = {}

try:
    import pathops  # skia-pathops, optional
except Exception:
    pathops = None


def glyph_name(cp):
    if cp in UV2AGL:
        return UV2AGL[cp]
    return "uni%04X" % cp


def contour_points(contour):
    """On-curve anchor points of a contour (for area/containment tests)."""
    pts = []
    for cmd in contour:
        op = cmd[0]
        if op == "move":
            pts.append((cmd[1], cmd[2]))
        elif op == "line":
            pts.append((cmd[1], cmd[2]))
        elif op == "curve":
            pts.append((cmd[5], cmd[6]))
    return pts


def signed_area(pts):
    a = 0.0
    n = len(pts)
    for i in range(n):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % n]
        a += x0 * y1 - x1 * y0
    return a / 2.0


def centroid(pts):
    return (sum(p[0] for p in pts) / len(pts),
            sum(p[1] for p in pts) / len(pts))


def point_in_poly(pt, poly):
    x, y = pt
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if ((yi > y) != (yj > y)) and \
           (x < (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi):
            inside = not inside
        j = i
    return inside


def reverse_contour(contour):
    """Reverse drawing direction of a (move ... close) contour."""
    pts = []        # on-curve points
    segs = []       # ('l',) or ('c', c1, c2)
    start = None
    for cmd in contour:
        op = cmd[0]
        if op == "move":
            start = (cmd[1], cmd[2])
            pts.append(start)
        elif op == "line":
            segs.append(("l",))
            pts.append((cmd[1], cmd[2]))
        elif op == "curve":
            segs.append(("c", (cmd[1], cmd[2]), (cmd[3], cmd[4])))
            pts.append((cmd[5], cmd[6]))
        # 'close' ignored here
    # Drop a duplicate trailing point equal to start (closed ring).
    if len(pts) > 1 and pts[-1] == pts[0]:
        pts = pts[:-1]
        # segs already aligns: seg i goes pts[i] -> pts[i+1] (mod)

    new = [["move", pts[-1][0], pts[-1][1]]]
    # Walk segments backwards. seg i connects pts[i] -> pts[i+1].
    for i in range(len(segs) - 1, -1, -1):
        seg = segs[i]
        target = pts[i]
        if seg[0] == "l":
            new.append(["line", target[0], target[1]])
        else:
            c1, c2 = seg[1], seg[2]
            new.append(["curve", c2[0], c2[1], c1[0], c1[1], target[0], target[1]])
    new.append(["close"])
    return new


def fix_winding(contours):
    """Orient contours for non-zero fill: even nesting depth CCW, odd CW."""
    polys = [contour_points(c) for c in contours]
    cents = [centroid(p) if p else (0, 0) for p in polys]
    out = []
    for i, c in enumerate(contours):
        if len(polys[i]) < 3:
            out.append(c)
            continue
        depth = 0
        for j, c2 in enumerate(contours):
            if i == j or len(polys[j]) < 3:
                continue
            if point_in_poly(cents[i], polys[j]):
                depth += 1
        area = signed_area(polys[i])          # >0 == CCW (y-up)
        want_ccw = (depth % 2 == 0)
        is_ccw = area > 0
        out.append(reverse_contour(c) if is_ccw != want_ccw else c)
    return out


def draw_contour(pen, contour):
    started = False
    for cmd in contour:
        op = cmd[0]
        if op == "move":
            pen.moveTo((cmd[1], cmd[2])); started = True
        elif op == "line":
            pen.lineTo((cmd[1], cmd[2]))
        elif op == "curve":
            pen.curveTo((cmd[1], cmd[2]), (cmd[3], cmd[4]), (cmd[5], cmd[6]))
        elif op == "close":
            if started:
                pen.closePath(); started = False
    if started:
        pen.closePath()


def cleanup_with_pathops(contours):
    """Resolve overlaps + fix winding via skia-pathops (even-odd source)."""
    path = pathops.Path()
    pen = path.getPen()
    for ct in contours:
        draw_contour(pen, ct)
    path.fillType = pathops.FillType.EVEN_ODD
    path.simplify()
    rec = RecordingPen()
    path.draw(rec)
    return rec


def build(spec_path, out_path):
    with open(spec_path) as f:
        spec = json.load(f)

    upem = spec["unitsPerEm"]
    family = spec["familyName"]
    style = spec["styleName"]
    ps_name = (family + "-" + style).replace(" ", "")

    glyph_order = [".notdef"]
    cmap = {}
    charstrings = {}
    metrics = {}

    ymin = 0
    ymax = 0
    advances = []

    # .notdef: empty glyph with a sensible width (filled in after we know avg).
    items = sorted(spec["glyphs"].items(), key=lambda kv: int(kv[0]))

    for cp_str, g in items:
        cp = int(cp_str)
        name = glyph_name(cp)
        if name in charstrings:
            continue
        glyph_order.append(name)
        cmap[cp] = name

        advance = int(round(g["advance"]))
        advances.append(advance)
        contours = [[list(cmd) for cmd in ct] for ct in g["contours"]]

        pen = T2CharStringPen(advance, None)
        if contours:
            if pathops is not None:
                rec = cleanup_with_pathops(contours)
                rec.replay(pen)
            else:
                for ct in fix_winding(contours):
                    draw_contour(pen, ct)
        cs = pen.getCharString()
        charstrings[name] = cs

        # track vertical extents + left side bearing
        xmin = None
        for ct in contours:
            for cmd in ct:
                if cmd[0] == "move" or cmd[0] == "line":
                    xs = [cmd[1]]; ys = [cmd[2]]
                elif cmd[0] == "curve":
                    xs = [cmd[1], cmd[3], cmd[5]]
                    ys = [cmd[2], cmd[4], cmd[6]]
                else:
                    continue
                for yv in ys:
                    ymin = min(ymin, yv); ymax = max(ymax, yv)
                for xv in xs:
                    xmin = xv if xmin is None else min(xmin, xv)
        lsb = int(round(xmin)) if xmin is not None else 0
        metrics[name] = (advance, lsb)

    # .notdef width = average advance (fallback 500)
    avg = int(round(sum(advances) / len(advances))) if advances else 500
    nd = T2CharStringPen(avg, None)
    nd.moveTo((0, 0)); nd.closePath()
    charstrings[".notdef"] = nd.getCharString()
    metrics[".notdef"] = (avg, 0)

    ascent = int(round(ymax)) or int(upem * 0.8)
    descent = int(round(ymin))            # negative
    if descent == 0:
        descent = -int(upem * 0.2)

    fb = FontBuilder(upem, isTTF=False)
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap(cmap)
    fb.setupCFF(
        ps_name,
        {"FullName": family + " " + style, "FamilyName": family,
         "Weight": style},
        charstrings,
        {},
    )
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=ascent, descent=descent, lineGap=0)
    fb.setupNameTable({
        "familyName": family,
        "styleName": style,
        "fullName": family + " " + style,
        "psName": ps_name,
        "version": "1.000",
    })
    fb.setupOS2(
        sTypoAscender=ascent, sTypoDescender=descent, sTypoLineGap=0,
        usWinAscent=max(ascent, 1), usWinDescent=abs(descent),
        sCapHeight=ascent, sxHeight=int(ascent * 0.66),
    )
    fb.setupPost()
    fb.save(out_path)


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2])
PYEOF
}
