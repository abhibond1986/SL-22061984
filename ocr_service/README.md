# Safety Lens OCR service

A small FastAPI service that reads text out of PDFs, Word `.docx` files and
photographs, then splits it into citable clauses. Safety Lens calls it from
`lib/services/doc_ocr_service.dart`.

## Why this is a separate service at all

PaddleOCR is Python-only. It cannot run in Dart, and it cannot run in Apps
Script. Safety Lens ships primarily as **Flutter Web**, where the existing
on-device OCR (`google_mlkit_text_recognition`) routes to a stub — so before
this service, web users had no OCR path at all, and no path for PDF or DOCX on
any platform.

Keeping it separate has a second benefit worth knowing: `paddleocr` pulls in
PyMuPDF (AGPL) transitively via `pdf2docx`. Because the app talks to this
service over plain HTTP rather than linking it, the Flutter app is not a derived
work. See the licence note in `requirements.txt`.

## What it does, per file type

| Input | How it is read |
| --- | --- |
| PDF, page has a text layer | `pdfplumber` — exact text, no OCR, near-instant |
| PDF, page has no text layer | `pypdfium2` rasterises → PaddleOCR |
| `.docx` | `python-docx`, **including tables** |
| Image | PaddleOCR |
| `.txt` / `.md` / `.csv` | read directly |

The text-layer decision is made **per page**, not per document, with a
100-character threshold (`MIN_TEXT_LAYER_CHARS` in `extractors.py`). Real plant
documents are routinely mixed: a digitally-produced SOP with a scanned annexure
stapled on the end. Deciding once per document would either OCR 40 perfect pages
for no reason, or skip OCR on the scanned pages and silently return nothing for
them.

`MAX_OCR_PAGES = 60` caps how many pages will be OCR'd in one request; beyond
that the response sets `meta.truncated: true` so the app can say so rather than
quietly answering from half a document.

## Endpoints

- `GET /` — one-line identity, useful for eyeballing a deployment
- `GET /health` — `{ok, modelWarm, maxUploadMb, ...}`
- `POST /warmup` — loads the model without doing work
- `POST /extract` — multipart: `file`, `lang`, `forceOcr`, `chunk`, `token`
- `POST /extract-b64` — same, base64 body, for callers that cannot do multipart

`/extract` returns:

```json
{
  "ok": true, "filename": "sop.pdf", "kind": "pdf",
  "text": "…", "pages": [{"page":1,"text":"…","method":"text-layer","confidence":null}],
  "chunks": [{"index":0,"text":"…","clause_no":"4.2.1","heading":"PPE","page_from":3,"page_to":3}],
  "meta": {"pageCount":12,"ocrPageCount":3,"charCount":18422,
           "meanConfidence":0.94,"ocrDerived":true,"truncated":false,"elapsedMs":41210}
}
```

## Environment variables

| Variable | Default | Notes |
| --- | --- | --- |
| `PORT` | `7860` | Hugging Face Spaces requires 7860 |
| `MAX_UPLOAD_MB` | `25` | Mirrored by `DocOcrService.maxUploadBytes` — change both |
| `OCR_API_TOKEN` | *(unset)* | Optional shared secret. Not a Gemini key; it only stops strangers burning your CPU quota. Treat it as public — it ships in the web bundle. |
| `ALLOWED_ORIGINS` | `*` | Comma-separated. **Set this to your real domain before release.** |
| `LOG_LEVEL` | `INFO` | |

## Deploying to Hugging Face Spaces (free CPU tier)

1. Create a new Space → **Docker** → blank template. Free CPU basic is enough.
2. Upload `Dockerfile`, `app.py`, `extractors.py`, `chunker.py`,
   `requirements.txt`. Do **not** upload `test_service.py` or `__pycache__`.
3. Settings → Variables and secrets: add `ALLOWED_ORIGINS` (your app's domain)
   and, if you want one, `OCR_API_TOKEN`.
4. Wait for the build. The first build takes roughly 10–15 minutes: paddlepaddle
   is a large wheel, and the Dockerfile deliberately **bakes the OCR models in at
   build time** so the first real request does not pay a model download.
5. Your URL is `https://<user>-<space-name>.hf.space`. Open it in a browser —
   you should see the identity JSON, not a Space loading page.

The Dockerfile already handles the two things that trip Spaces up: it runs as
UID 1000 with `HOME=/home/user` (Spaces runs unprivileged, and PaddleOCR writes
its model cache under `$HOME`), and it uses `opencv-python-headless` because the
GUI build needs `libGL`, which slim images do not have.

### Cold starts are real, and expected

Free hosting suspends an idle container. The first request after a sleep pays
container boot plus model load — up to a minute. This is why
`DocOcrService.warmUp()` is called when the Q&A screen opens, and why the
timeouts in that file are generous (5 minutes for an extraction). A scanned
40-page SOP on a free CPU genuinely takes minutes; the UI shows progress so the
wait is visible rather than looking like a hang.

## Running locally

```bash
pip install -r requirements.txt
uvicorn app:app --reload --port 7860
```

Then point the app at `http://localhost:7860` — either
`--dart-define=DOC_OCR_URL=http://localhost:7860` at build time, or via
`DocOcrService.setServiceUrl()` from the admin screen at runtime.

## Tests

```bash
python3 test_service.py
```

18 checks in two tiers. Tier 1 (17 checks) runs **without** PaddleOCR installed
— it covers the chunker, both PaddleOCR result shapes (2.x list and 3.x dict),
`clean_text`, the DOCX reader including tables, the PDF text-layer preference,
and corrupt-file handling. Tier 2 (1 check) needs the real `paddleocr` package
and OCRs a generated image.

Last verified: **18/18 passing** on Python 3.10 with `paddleocr 2.7.3` /
`paddlepaddle 2.6.2`. The `pdfplumber could not open the PDF (No /Root object!)`
line printed during the run is the corrupt-PDF fixture doing its job, not a
failure.

## Two design notes that are easy to undo by accident

**`clean_text` is deliberately conservative.** It fixes control characters,
hyphenated line breaks and bare page numbers. It does **not** fix spelling.
"Correcting" what looks like a garbled clause number or chemical name would be
worse than leaving it visibly wrong, because a plausible-looking wrong figure is
acted on and a visibly garbled one is checked.

**Chunking is clause-aware, not fixed-size.** A chunk that straddles two clauses
produces an answer citing the wrong rule — which in a safety document is a
defect, not merely a relevance problem. `chunker.py` splits on clause numbers
(`4.2.1`) and headings first, and only falls back to size (`TARGET_CHARS = 1400`)
inside a clause that is genuinely too long. There is a test asserting a clause
never splits across chunks; if you change the splitter, keep it passing.
