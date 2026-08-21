"""
app.py — Safety Lens OCR microservice (FastAPI + PaddleOCR).

Exposes a free, self-hostable OCR + text-extraction endpoint for the Safety
Lens Flutter Web app, which cannot use the existing on-device ML Kit OCR
(google_mlkit_text_recognition has no web implementation).

Endpoints
---------
GET  /            Service metadata
GET  /health      Liveness + whether the OCR model is warm
POST /warmup      Force model load (call after a cold start)
POST /extract     multipart file upload -> extracted text + chunks
POST /extract-b64 JSON {filename, contentBase64} -> same

Run locally:
    uvicorn app:app --host 0.0.0.0 --port 7860 --reload

Deploy: see README.md (Hugging Face Spaces, Docker SDK, free CPU tier).
"""

from __future__ import annotations

import base64
import binascii
import logging
import os
import time
from typing import List, Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

import extractors
from chunker import chunk_pages
from extractors import (
    ExtractResult,
    PageResult,
    UnsupportedDocument,
    clean_text,
    extract_docx,
    extract_pdf,
    ocr_image_bytes,
)

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("safetylens.api")

SERVICE_VERSION = "1.0.0"

# Free hosting tiers give ~512 MB-2 GB RAM. A 25 MB cap keeps a single
# request from exhausting memory while still accepting a scanned 60-page SOP.
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "25"))
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024

# Shared-secret gate. Optional but strongly recommended once the Space is
# public, otherwise anyone can burn your CPU quota. Set OCR_API_TOKEN in the
# host's secret settings and the same value in the Flutter client.
API_TOKEN = os.environ.get("OCR_API_TOKEN", "").strip()

# Flutter Web sends cross-origin requests, so CORS is mandatory. Defaults to
# "*" for first-run convenience; set ALLOWED_ORIGINS to your real domain
# (e.g. https://safetylens.example.com) before going live.
_origins_raw = os.environ.get("ALLOWED_ORIGINS", "*").strip()
ALLOWED_ORIGINS = ["*"] if _origins_raw == "*" else [
    o.strip() for o in _origins_raw.split(",") if o.strip()
]

IMAGE_EXTS = {"png", "jpg", "jpeg", "webp", "bmp", "tif", "tiff", "gif"}
TEXT_EXTS = {"txt", "md", "csv", "log"}

app = FastAPI(
    title="Safety Lens OCR Service",
    description="PaddleOCR-backed text extraction for PDF, DOCX and images.",
    version=SERVICE_VERSION,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


# --------------------------------------------------------------------------
# Models
# --------------------------------------------------------------------------

class Base64Request(BaseModel):
    filename: str = Field(..., description="Original filename, used to pick the reader")
    contentBase64: str = Field(..., description="Raw file bytes, base64-encoded")
    lang: str = "en"
    forceOcr: bool = False
    chunk: bool = True
    token: Optional[str] = None


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def _ext_of(filename: str) -> str:
    return (filename or "").rsplit(".", 1)[-1].lower() if "." in (filename or "") else ""


def _check_token(supplied: Optional[str]) -> None:
    if not API_TOKEN:
        return
    if (supplied or "").strip() != API_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid or missing API token.")


def _dispatch(filename: str, data: bytes, lang: str, force_ocr: bool) -> ExtractResult:
    """Route the file to the right reader based on its extension."""
    ext = _ext_of(filename)

    if ext == "pdf":
        return extract_pdf(data, lang=lang, force_ocr=force_ocr)

    if ext == "docx":
        return extract_docx(data)

    if ext == "doc":
        # The legacy binary .doc format needs LibreOffice to read; adding it
        # would roughly triple the container size for a format SAIL is phasing
        # out. Give an actionable message instead of a vague failure.
        raise UnsupportedDocument(
            "Old .doc files aren't supported. Please open it in Word and "
            "'Save As' .docx, then upload again."
        )

    if ext in IMAGE_EXTS:
        text, conf = ocr_image_bytes(data, lang=lang)
        res = ExtractResult(kind="image")
        res.pages.append(
            PageResult(page=1, text=clean_text(text), method="paddleocr", confidence=conf)
        )
        return res

    if ext in TEXT_EXTS:
        res = ExtractResult(kind="text")
        decoded = data.decode("utf-8", errors="replace")
        res.pages.append(PageResult(page=1, text=clean_text(decoded), method="text-layer"))
        return res

    raise UnsupportedDocument(
        f"Unsupported file type '.{ext or '?'}'. Supported: PDF, DOCX, "
        "PNG/JPG/WEBP/TIFF images, and plain text."
    )


def _build_response(
    filename: str, result: ExtractResult, want_chunks: bool, elapsed_ms: int
) -> dict:
    pages = [
        {
            "page": p.page,
            "text": p.text,
            "method": p.method,
            "confidence": p.confidence,
        }
        for p in result.pages
    ]

    chunks: List[dict] = []
    if want_chunks:
        chunks = [c.to_dict() for c in chunk_pages(pages)]

    full_text = result.text

    return {
        "ok": True,
        "filename": filename,
        "kind": result.kind,
        "text": full_text,
        "pages": pages,
        "chunks": chunks,
        "meta": {
            "pageCount": len(pages),
            "ocrPageCount": result.ocr_page_count,
            "charCount": len(full_text),
            "chunkCount": len(chunks),
            "meanConfidence": result.mean_confidence,
            # True when OCR produced most of the text, so the client can mark
            # the document unverified in the KB (matching the existing
            # trusted-vs-sop_scan_raw distinction).
            "ocrDerived": result.ocr_page_count > 0,
            "truncated": result.truncated,
            "elapsedMs": elapsed_ms,
            "serviceVersion": SERVICE_VERSION,
        },
    }


def _extract_or_error(filename: str, data: bytes, lang: str,
                      force_ocr: bool, want_chunks: bool) -> dict:
    if not data:
        raise HTTPException(status_code=400, detail="The uploaded file was empty.")
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File is {len(data) // (1024*1024)} MB; the limit is "
                   f"{MAX_UPLOAD_MB} MB. Please split the document.",
        )

    started = time.time()
    try:
        result = _dispatch(filename, data, lang, force_ocr)
    except UnsupportedDocument as exc:
        raise HTTPException(status_code=415, detail=str(exc)) from exc
    except MemoryError as exc:
        raise HTTPException(
            status_code=507,
            detail="Ran out of memory reading that document. Try splitting it.",
        ) from exc
    except Exception as exc:
        log.exception("Extraction failed for %s", filename)
        raise HTTPException(
            status_code=500, detail=f"Extraction failed: {exc}"
        ) from exc

    elapsed_ms = int((time.time() - started) * 1000)

    if not result.text.strip():
        # Not an error — a blank scan or a pure-diagram page is a real outcome.
        # Return ok:true with an explanatory note so the UI can say something
        # useful rather than showing an empty box.
        payload = _build_response(filename, result, want_chunks, elapsed_ms)
        payload["note"] = (
            "No readable text was found. If this is a photo, try better "
            "lighting, hold the camera square to the page, and make sure the "
            "text fills the frame."
        )
        return payload

    log.info(
        "Extracted %s: kind=%s pages=%d ocr=%d chars=%d in %dms",
        filename, result.kind, len(result.pages),
        result.ocr_page_count, len(result.text), elapsed_ms,
    )
    return _build_response(filename, result, want_chunks, elapsed_ms)


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

@app.get("/")
def root() -> dict:
    return {
        "service": "Safety Lens OCR Service",
        "version": SERVICE_VERSION,
        "engine": "PaddleOCR (CPU)",
        "supported": sorted({"pdf", "docx"} | IMAGE_EXTS | TEXT_EXTS),
        "endpoints": ["/health", "/warmup", "/extract", "/extract-b64"],
        "authRequired": bool(API_TOKEN),
        "maxUploadMb": MAX_UPLOAD_MB,
    }


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "version": SERVICE_VERSION,
        # Warm means the model is already in RAM, so the next OCR is fast.
        "modelWarm": bool(extractors._ocr_cache),
        "loadedLangs": sorted(extractors._ocr_cache.keys()),
    }


@app.post("/warmup")
def warmup(lang: str = Form("en"), token: Optional[str] = Form(None)) -> dict:
    """
    Pre-load the OCR model.

    Free hosting tiers suspend idle containers, so the first real request after
    a sleep would otherwise pay ~10-20 s of model init. The Flutter client
    fires this as soon as the user opens the Document Q&A screen, so the model
    is usually warm by the time they finish choosing a file.
    """
    _check_token(token)
    started = time.time()
    try:
        extractors.get_paddle(lang)
    except Exception as exc:
        log.exception("Warmup failed")
        raise HTTPException(status_code=500, detail=f"Warmup failed: {exc}") from exc
    return {"ok": True, "lang": lang, "elapsedMs": int((time.time() - started) * 1000)}


@app.post("/extract")
async def extract(
    file: UploadFile = File(...),
    lang: str = Form("en"),
    forceOcr: bool = Form(False),
    chunk: bool = Form(True),
    token: Optional[str] = Form(None),
) -> dict:
    """Primary endpoint: multipart upload."""
    _check_token(token)
    data = await file.read()
    return _extract_or_error(
        file.filename or "upload", data, lang, forceOcr, chunk
    )


@app.post("/extract-b64")
def extract_b64(req: Base64Request) -> dict:
    """
    JSON/base64 alternative.

    Useful when the caller cannot easily build a multipart body — notably
    Google Apps Script's UrlFetchApp, if you ever proxy OCR server-side to
    keep the OCR token out of the browser.
    """
    _check_token(req.token)
    try:
        data = base64.b64decode(req.contentBase64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(
            status_code=400, detail="contentBase64 is not valid base64."
        ) from exc
    return _extract_or_error(
        req.filename, data, req.lang, req.forceOcr, req.chunk
    )


if __name__ == "__main__":
    import uvicorn

    # 7860 is the port Hugging Face Spaces expects.
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "7860")),
    )
