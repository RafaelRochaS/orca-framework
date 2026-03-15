FROM python:3.11-slim

LABEL org.opencontainers.image.title="ETSI OpenOP Orchestrator"
LABEL org.opencontainers.image.description="CAMARA → 5GC + RIC translation engine"

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/

EXPOSE 8090

HEALTHCHECK --interval=10s --timeout=5s --retries=6 --start-period=15s \
  CMD curl -f http://localhost:8090/healthz || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8090", "--log-level", "info"]
