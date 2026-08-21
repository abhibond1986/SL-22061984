"""
chunker.py — split extracted document text into retrievable chunks.

Why not a plain fixed-size splitter
-----------------------------------
Safety Lens already treats the SOP *clause* as its unit of knowledge: the
existing SOP-scan flow writes one `knowledge_docs` row per clause, carrying
`sopNumber` / `clauseNo` / `pageFrom`. Answers are cited back to a safety
officer as "SOP 4.2.1 says ...", so a chunk that straddles two clauses
produces a citation that points at the wrong rule. That is a safety problem,
not just a relevance problem.

So we split on structure first (numbered clauses and headings), and only fall
back to size-based splitting inside a clause that is too long to embed whole.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, asdict
from typing import List, Optional

# Target chunk size in characters. ~1400 chars is roughly 350 tokens, which
# lets us fit 5-6 chunks into a Gemini Flash prompt alongside the safety
# system prompt with plenty of headroom.
TARGET_CHARS = 1400

# Chunks shorter than this get merged into their neighbour. A bare heading
# like "5. HAZARDS" retrieves noisily on its own and tells the model nothing.
MIN_CHARS = 120

# Overlap when a long clause must be split mid-flow, so a control measure
# that spans the split boundary still appears whole in at least one chunk.
OVERLAP_CHARS = 180

# Matches "4.", "4.2", "4.2.1", "4.2.1.3" at line start, optionally followed
# by a heading. Rejects decimals in running prose ("a 2.5 m platform") by
# requiring line-start plus a following space/tab or end-of-line.
_RE_CLAUSE = re.compile(
    r"^[ \t]*((?:\d{1,3})(?:\.\d{1,3}){0,3})\.?[ \t)]+(?=\S)"
)

# Markdown-ish heading emitted by the DOCX extractor, or an ALL-CAPS heading
# line which is how most SAIL SOP sections are typeset.
_RE_HEADING = re.compile(r"^[ \t]*##[ \t]+(.+)$")
_RE_CAPS_HEADING = re.compile(r"^[ \t]*([A-Z][A-Z0-9 ,./&()\-]{4,70})[ \t]*:?[ \t]*$")

_RE_SENTENCE_END = re.compile(r"(?<=[.!?:;])\s+")


@dataclass
class Chunk:
    index: int
    text: str
    clause_no: Optional[str] = None
    heading: Optional[str] = None
    page_from: Optional[int] = None
    page_to: Optional[int] = None
    char_count: int = 0

    def to_dict(self) -> dict:
        d = asdict(self)
        d["char_count"] = len(self.text)
        return d


@dataclass
class _Block:
    """An intermediate structural unit before size-normalisation."""
    lines: List[str]
    clause_no: Optional[str]
    heading: Optional[str]
    page_from: Optional[int]
    page_to: Optional[int]

    @property
    def text(self) -> str:
        return "\n".join(self.lines).strip()


def chunk_pages(pages: List[dict]) -> List[Chunk]:
    """
    Build chunks from per-page extraction results.

    `pages` is a list of {"page": int, "text": str} — the shape produced by
    extractors.ExtractResult. Page numbers are tracked through so a citation
    can say which page a quote came from.
    """
    blocks = _structural_blocks(pages)
    blocks = _merge_tiny(blocks)

    chunks: List[Chunk] = []
    for block in blocks:
        body = block.text
        if not body:
            continue
        if len(body) <= TARGET_CHARS:
            chunks.append(
                Chunk(
                    index=len(chunks),
                    text=body,
                    clause_no=block.clause_no,
                    heading=block.heading,
                    page_from=block.page_from,
                    page_to=block.page_to,
                )
            )
        else:
            for piece in _split_long(body):
                chunks.append(
                    Chunk(
                        index=len(chunks),
                        text=piece,
                        clause_no=block.clause_no,
                        heading=block.heading,
                        page_from=block.page_from,
                        page_to=block.page_to,
                    )
                )

    for c in chunks:
        c.char_count = len(c.text)
    return chunks


def _structural_blocks(pages: List[dict]) -> List[_Block]:
    """Walk every line, starting a new block at each clause number or heading."""
    blocks: List[_Block] = []
    current: Optional[_Block] = None
    current_heading: Optional[str] = None

    def flush():
        nonlocal current
        if current is not None and current.text:
            blocks.append(current)
        current = None

    for page in pages:
        page_no = page.get("page")
        for raw_line in (page.get("text") or "").split("\n"):
            line = raw_line.rstrip()
            if not line.strip():
                if current is not None:
                    current.lines.append("")
                continue

            md = _RE_HEADING.match(line)
            caps = None if md else _RE_CAPS_HEADING.match(line)
            clause = _RE_CLAUSE.match(line)

            if md or caps:
                flush()
                current_heading = (md.group(1) if md else caps.group(1)).strip()
                current = _Block(
                    lines=[current_heading],
                    clause_no=None,
                    heading=current_heading,
                    page_from=page_no,
                    page_to=page_no,
                )
                continue

            if clause:
                flush()
                current = _Block(
                    lines=[line.strip()],
                    clause_no=clause.group(1),
                    heading=current_heading,
                    page_from=page_no,
                    page_to=page_no,
                )
                continue

            if current is None:
                current = _Block(
                    lines=[line.strip()],
                    clause_no=None,
                    heading=current_heading,
                    page_from=page_no,
                    page_to=page_no,
                )
            else:
                current.lines.append(line.strip())
                current.page_to = page_no

    flush()
    return blocks


def _merge_tiny(blocks: List[_Block]) -> List[_Block]:
    """
    Fold undersized blocks forward into the next one.

    A heading-only block is merged into the section it introduces, which keeps
    the heading text available as retrieval signal for that section's content.
    """
    if not blocks:
        return blocks

    out: List[_Block] = []
    pending: Optional[_Block] = None

    for block in blocks:
        if pending is not None:
            merged_text_len = len(pending.text) + len(block.text) + 1
            if merged_text_len <= TARGET_CHARS:
                block = _Block(
                    lines=pending.lines + block.lines,
                    # Keep the FIRST clause number: it is the one a citation
                    # should name, since the tiny block came first.
                    clause_no=pending.clause_no or block.clause_no,
                    heading=pending.heading or block.heading,
                    page_from=pending.page_from,
                    page_to=block.page_to,
                )
            else:
                out.append(pending)
            pending = None

        if len(block.text) < MIN_CHARS:
            pending = block
        else:
            out.append(block)

    if pending is not None:
        # Nothing followed it — attach backwards rather than lose the text.
        if out and len(out[-1].text) + len(pending.text) + 1 <= TARGET_CHARS * 1.5:
            out[-1].lines.extend(pending.lines)
            out[-1].page_to = pending.page_to
        else:
            out.append(pending)

    return out


def _split_long(text: str) -> List[str]:
    """Size-split an over-long block on sentence boundaries, with overlap."""
    sentences = _RE_SENTENCE_END.split(text)
    pieces: List[str] = []
    buf = ""

    for sentence in sentences:
        candidate = (buf + " " + sentence).strip() if buf else sentence.strip()
        if len(candidate) <= TARGET_CHARS:
            buf = candidate
            continue

        if buf:
            pieces.append(buf)
            tail = buf[-OVERLAP_CHARS:]
            # Start the overlap at a word boundary so we don't lead with a
            # fragment like "rmit required before".
            space = tail.find(" ")
            buf = (tail[space + 1:] if space != -1 else tail) + " " + sentence.strip()
            buf = buf.strip()
        else:
            buf = sentence.strip()

        # A single sentence longer than the target (common in OCR'd tables
        # where row breaks are lost) still has to be broken somewhere.
        while len(buf) > TARGET_CHARS:
            cut = buf.rfind(" ", 0, TARGET_CHARS)
            if cut <= 0:
                cut = TARGET_CHARS
            pieces.append(buf[:cut].strip())
            buf = buf[max(0, cut - OVERLAP_CHARS):].strip()

    if buf:
        pieces.append(buf)

    return [p for p in pieces if p.strip()]
