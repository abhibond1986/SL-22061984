# Safety Lens OCR service — PaddleOCR on CPU.
#
# Targets Hugging Face Spaces (Docker SDK, free CPU tier) but is a plain
# container and runs anywhere: Render, Fly.io, Cloud Run, or locally.

FROM python:3.10-slim

# PaddleOCR/OpenCV need a handful of native libs that slim images omit.
# libgomp1 is the one people miss — paddle segfaults without it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 \
        libglib2.0-0 \
        libsm6 \
        libxext6 \
        libxrender1 \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Hugging Face Spaces runs containers as UID 1000 with $HOME=/home/user.
# Running as root there makes PaddleOCR's model cache unwritable at runtime,
# which surfaces as a confusing permission error on the first OCR call.
RUN useradd -m -u 1000 user
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    OMP_NUM_THREADS=2

WORKDIR /app

COPY --chown=user requirements.txt .
USER user
RUN pip install --no-cache-dir --user -r requirements.txt

COPY --chown=user *.py ./

# Bake the detection/recognition/angle models into the image.
# Without this, the first request after every cold start downloads ~20 MB from
# Baidu's CDN — slow, and it fails outright on hosts with no egress. Baking
# them makes cold starts predictable and the container works offline.
RUN python -c "from paddleocr import PaddleOCR; PaddleOCR(use_angle_cls=True, lang='en', show_log=False)" \
    || echo "WARN: model pre-download failed; models will be fetched at first use"

EXPOSE 7860

# Single worker on purpose: each worker loads its own ~400 MB copy of the
# PaddleOCR model, so 2 workers OOM a free 2 GB box. Scale with replicas, not
# workers. --timeout-keep-alive is raised because OCR'ing a long scanned SOP
# can legitimately hold the connection for a couple of minutes.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "7860", \
     "--workers", "1", "--timeout-keep-alive", "120"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -fsS http://localhost:7860/health || exit 1
