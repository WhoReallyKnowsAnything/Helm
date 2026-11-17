#!/bin/zsh
# The design gate (AC4): flags raw values a screen must take from the design kit.
# Usage: scripts/design-gates.sh [file or folder ...]      (default: Sources)
# Flags: literal fonts, numeric padding, numeric spacing, numeric .frame( sizes, colour literals, raw SF Symbol names.
# Skips, even when named: DesignKit/Tokens.swift, DesignKit/KitIcon.swift and the migration alias DesignKit/Theme.swift.
# shortcut: a size inside a nested expression such as .frame(width: min(max(a, 200), 600)) is not flagged, upgrade when one slips through.
# Exit 1 with file:line for every hit, 0 when clean.
set -uo pipefail
paths=("$@")
(( $#paths )) || paths=(${0:A:h:h}/Sources)
find "${paths[@]}" -name '*.swift' -not -name 'Tokens.swift' -not -name 'KitIcon.swift' -not -path '*/DesignKit/Theme.swift' -print0 | xargs -0 perl -ne '
  BEGIN { $count = 0 }
  if (!/^\s*\/\//) {
    my @hit;
    push @hit, "literal font" if /\.system\(size:/;
    push @hit, "numeric padding" if /\.padding\((?:\.\w+|\[[^\]]*\])?,?\s*-?\d/;
    push @hit, "numeric spacing" if /spacing:\s*-?\d/;
    push @hit, "numeric frame" if /\.frame\(.*?\b(?:min|max|ideal)?(?:[Ww]idth|[Hh]eight):\s*-?\d/;
    push @hit, "colour literal" if /\b0x[0-9A-Fa-f]{6}\b/ || /(?:Color\(red:|NSColor\(srgbRed:)\s*-?[\d.]/ || /Color\(hex/;
    push @hit, "raw symbol" if /\b(?:systemImage|systemName):/;
    if (@hit) { $count++; my $l = $_; $l =~ s/^\s+//; print "$ARGV:$.: ", join(", ", @hit), ": $l"; }
  }
  close ARGV if eof;
  END { if ($count) { print "FAIL design-gates: $count lines use raw values\n"; exit 1 } print "PASS design-gates\n" }'
# xargs turns the perl exit 1 into 123, so the script reports a plain 1.
(( ${pipestatus[2]} == 0 )) || exit 1
