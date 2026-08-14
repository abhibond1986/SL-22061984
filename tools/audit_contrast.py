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


def scan_fill_only_as_text():
    """Flag `AppColors.<fillOnly>` used as a color: on text or icons.

    Deliberately skips equality comparisons (`color == AppColors.x`) — those
    read the token, they don't render it.
    """
    hits = []
    pat = re.compile(r'color:\s*AppColors\.(\w+)')
    for path in dart_files():
        for n, line in enumerate(open(path, encoding='utf-8'), 1):
            if '==' in line:
                continue
            ctx = line
            if not re.search(r'TextStyle|Icon\(|Icon\b', ctx):
                continue
            for tok in pat.findall(ctx):
                if tok in FILL_ONLY:
                    hits.append((rel(path), n, tok, line.strip()))
    return hits


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
