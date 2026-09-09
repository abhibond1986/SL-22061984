#!/usr/bin/env python3
"""
Safety Lens — readability audit (WCAG contrast + type floor).

Run from the repo root:      python3 tools/audit_contrast.py
Gate a release:              python3 tools/audit_contrast.py --strict   (exit 1 on any FAIL)

WHY THIS EXISTS
---------------
Two failure modes kept coming back and neither is visible in a code review:

1. A status colour doing double duty. `AppColors.amber` was tuned as a FILL
   (a chip background) and then reused as TEXT, where it lands at ~2.2:1 on
   white — unreadable. Crucially no single hex can serve both themes: a value
   with enough contrast on white is usually too dark on the graphite dark bg,
   and vice versa. That is why the *Light variants exist, and why this script
   scores every token against BOTH backgrounds rather than one.

2. Micro type. Badge and pill labels drifted down to 6-7px on screen.

2026-09-09: the fill-only scan is now MULTILINE-AWARE. It used to require the
enclosing `TextStyle`/`Icon(` on the same physical line as `color:`, so it
reported 2 violations where the tree actually had ~91 — everything wrapped over
two lines or written as a ternary walked straight past it. Expect the failure
count to jump the first time you run this after updating; that is the blind spot
closing, not a regression. See scan_fill_only_as_text() for the heuristic and its
known limits.

KNOWN BLIND SPOT (still open): every token here is scored against the two GLOBAL
backgrounds, never against a local card fill. Recolouring a card silently changes
the contrast of every widget sitting on it and this total does not move. When a
card fill changes, hand-measure every foreground on it — including widgets your
diff did not touch.

The script parses the SHIPPED lib/main.dart, so it audits reality rather than a
copy that can silently diverge.

pdf_export*.dart is excluded from the type floor on purpose: those numbers are
POINTS on an A4 page, not logical screen pixels, and 7pt is normal in a printed
table.
"""

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(REPO, 'lib', 'main.dart')
LIB = os.path.join(REPO, 'lib')

# Logical-pixel floor for on-screen text. 11 is the comfortable target; below
# TYPE_FAIL it is not readable at arm's length on a plant floor, often in
# gloves and poor light, which is the actual use context.
TYPE_WARN = 11
TYPE_FAIL = 10

TYPE_FLOOR_EXCLUDE = ('pdf_export',)

# Tokens that are legitimately FILLS ONLY — flagged if used as text/icon colour.
FILL_ONLY = {'crit', 'red', 'amber', 'green', 'accent', 'accentDark',
             'accentGlow', 'cyan', 'purple', 'pink'}


# ── colour maths (WCAG 2.1) ────────────────────────────────────────────────
def parse_hex(s):
    s = s.strip().upper().replace('0X', '')
    if len(s) == 8:          # AARRGGBB
        s = s[2:]
    return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)


def luminance(rgb):
    def chan(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (chan(x) for x in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(fg, bg):
    l1, l2 = luminance(fg), luminance(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


# ── parse AppColors out of the real main.dart ─────────────────────────────
def load_tokens():
    if not os.path.exists(MAIN):
        sys.exit('cannot find lib/main.dart — run me from the repo root')
    src = open(MAIN, encoding='utf-8').read()
    m = re.search(r'class AppColors\s*\{(.*?)\n\}', src, re.S)
    if not m:
        sys.exit('could not locate class AppColors in lib/main.dart')
    body = m.group(1)

    direct = dict(re.findall(
        r'static const (\w+)\s*=\s*Color\(\s*(0x[0-9a-fA-F]{8})\s*\)', body))
    alias = dict(re.findall(r'static const (\w+)\s*=\s*(\w+)\s*;', body))

    tokens = {k: parse_hex(v) for k, v in direct.items()}
    for _ in range(5):                      # resolve alias chains
        for k, v in alias.items():
            if k not in tokens and v in tokens:
                tokens[k] = tokens[v]
    return tokens


# ── find status tokens used as foreground ─────────────────────────────────
def dart_files():
    for root, _, files in os.walk(LIB):
        for f in files:
            if f.endswith('.dart'):
                yield os.path.join(root, f)


def rel(p):
    return os.path.relpath(p, REPO).replace(os.sep, '/')


# Constructors that make a colour a FOREGROUND (text or a meaning-carrying
# glyph) versus a BACKGROUND/decoration fill, where a fill-only token is fine.
# Used by the nearest-enclosing-marker heuristic in scan_fill_only_as_text().
FG_MARKERS = (
    'TextStyle(', 'Icon(', 'ImageIcon(', 'IconTheme(', 'foregroundColor:',
    'selectionColor:', 'cursorColor:', 'iconColor:', 'prefixIconColor:',
    'suffixIconColor:', 'labelStyle:', 'hintStyle:', 'checkColor:',
)
BG_MARKERS = (
    'BoxDecoration(', 'BoxShadow(', 'LinearGradient(', 'RadialGradient(',
    'SweepGradient(', 'Border.all(', 'BorderSide(', 'backgroundColor:',
    'fillColor:', 'barrierColor:', 'shadowColor:', 'overlayColor:',
    'splashColor:', 'highlightColor:', 'indicatorColor:', 'dividerColor:',
    'trackColor:', 'thumbColor:', 'progressColor:', 'seedColor:',
    'surfaceTintColor:', 'Container(', 'CircleAvatar(', 'Divider(',
    'ColorFilter.mode(',
)

# How far back to look for the enclosing constructor. Long enough to clear a
# multi-line TextStyle, short enough not to bleed into the previous widget.
_LOOKBACK = 260


def scan_fill_only_as_text():
    """Flag `AppColors.<fillOnly>` used as a FOREGROUND colour.

    MULTILINE-AWARE. The original version required `TextStyle`/`Icon(` to appear
    on the SAME LINE as `color:`, which is how it reported 2 hits while a grep
    over the same tree found 318 (UI_UX_AUDIT.md §3). Any of these escaped it:

        Text(s, style: TextStyle(
            color: AppColors.amber,        <- marker one line up
            fontSize: 11))
        Icon(i,
            color: bad ? AppColors.red : AppColors.green)   <- ternary

    So instead of matching line-locally, this reads whole files and classifies
    each `color:`/`foregroundColor:` site by its NEAREST PRECEDING constructor
    marker: a TextStyle/Icon nearer than any BoxDecoration/gradient means the
    token is being painted as a foreground.

    This is a heuristic, not a parser, and it will occasionally misjudge deeply
    nested builders. It errs toward reporting, because a false positive costs a
    glance and a false negative costs unreadable safety text.

    Equality comparisons (`color == AppColors.x`) are skipped — they read the
    token, they don't render it.
    """
    hits = []
    pat = re.compile(r'(?:color|foregroundColor)\s*:\s*'
                     r'(?:[^;\n]{0,80}?)?AppColors\.(\w+)')
    for path in dart_files():
        src = open(path, encoding='utf-8').read()
        line_of = _line_index(src)
        lines = src.splitlines()
        for m in pat.finditer(src):
            tok = m.group(1)
            if tok not in FILL_ONLY:
                continue
            head = src[max(0, m.start() - _LOOKBACK):m.start()]
            if '==' in head[-40:] or '!=' in head[-40:]:
                continue
            fg = max((head.rfind(k) for k in FG_MARKERS), default=-1)
            bg = max((head.rfind(k) for k in BG_MARKERS), default=-1)
            if fg <= bg:
                continue                       # decoration fill — legitimate
            n = line_of(m.start())
            hits.append((rel(path), n, tok, lines[n - 1].strip()))
    return hits


def _line_index(src):
    """Return a fn mapping a character offset to a 1-based line number."""
    breaks = [i for i, ch in enumerate(src) if ch == '\n']

    def at(off):
        import bisect
        return bisect.bisect_right(breaks, off - 1) + 1
    return at


def scan_type_floor():
    warn, fail = [], []
    pat = re.compile(r'fontSize:\s*(\d+(?:\.\d+)?)')
    for path in dart_files():
        r = rel(path)
        if any(x in r for x in TYPE_FLOOR_EXCLUDE):
            continue
        for n, line in enumerate(open(path, encoding='utf-8'), 1):
            for v in pat.findall(line):
                size = float(v)
                rec = (r, n, size, line.strip()[:90])
                if size < TYPE_FAIL:
                    fail.append(rec)
                elif size < TYPE_WARN:
                    warn.append(rec)
    return warn, fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--strict', action='store_true',
                    help='exit non-zero if anything FAILS')
    ap.add_argument('--quiet', action='store_true',
                    help='summary only')
    args = ap.parse_args()

    tokens = load_tokens()
    light = tokens.get('lightCard', (255, 255, 255))
    dark = tokens.get('darkCard', (23, 31, 44))
    failures = 0

    print('=' * 74)
    print('CONTRAST OF STATUS/ACCENT TOKENS AS TEXT  (AA body 4.5, AA large 3.0)')
    print(f'  light surface {light}    dark surface {dark}')
    print('=' * 74)
    print(f'{"token":<14}{"on light":>10}{"on dark":>10}   verdict')
    interest = [t for t in tokens
                if t in FILL_ONLY or t.endswith('Light')
                or t.startswith('text')]
    for t in sorted(interest):
        cl = contrast(tokens[t], light)
        cd = contrast(tokens[t], dark)
        ok_l, ok_d = cl >= 4.5, cd >= 4.5
        if ok_l and ok_d:
            verdict = 'ok both themes'
        elif ok_l:
            verdict = 'LIGHT ONLY — fails on dark'
        elif ok_d:
            verdict = 'DARK ONLY — fails on light'
        else:
            verdict = 'FAILS BOTH — fill only'
        print(f'{t:<14}{cl:>9.2f}:1{cd:>9.2f}:1   {verdict}')

    print()
    print('=' * 74)
    print('FILL-ONLY TOKENS USED AS TEXT / ICON COLOUR')
    print('=' * 74)
    hits = scan_fill_only_as_text()
    if not hits:
        print('  none — clean')
    else:
        failures += len(hits)
        for f, n, tok, line in hits:
            print(f'  FAIL {f}:{n}  AppColors.{tok}')
            if not args.quiet:
                print(f'        {line[:100]}')

    print()
    print('=' * 74)
    print(f'TYPE FLOOR  (fail < {TYPE_FAIL}px, warn < {TYPE_WARN}px; '
          f'excludes {", ".join(TYPE_FLOOR_EXCLUDE)})')
    print('=' * 74)
    warn, fail = scan_type_floor()
    if fail:
        failures += len(fail)
        for f, n, size, line in fail:
            print(f'  FAIL {f}:{n}  {size:g}px')
            if not args.quiet:
                print(f'        {line}')
    else:
        print(f'  no on-screen text below {TYPE_FAIL}px — clean')
    print(f'  warnings ({TYPE_FAIL}-{TYPE_WARN - 1}px): {len(warn)}')
    if warn and not args.quiet:
        from collections import Counter
        for f, c in Counter(w[0] for w in warn).most_common(12):
            print(f'      {c:>4}  {f}')

    print()
    print('=' * 74)
    print(f'SUMMARY: {failures} failure(s), {len(warn)} warning(s)')
    print('=' * 74)
    if args.strict and failures:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
