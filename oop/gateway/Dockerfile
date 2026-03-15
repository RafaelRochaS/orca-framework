# =============================================================================
# ETSI OpenOP — CAMARA API Gateway
# Lightweight FastAPI-based gateway that exposes CAMARA-compliant APIs
# and translates them to Open5GS NEF/PCF calls southbound.
#
# In a full OpenOP deployment, replace this with the actual ETSI OOP image.
# This Dockerfile provides a ready-to-extend scaffold for CAMARA API research.
# =============================================================================
FROM python:3.11-slim

LABEL org.opencontainers.image.title="ETSI OpenOP CAMARA Gateway"
LABEL org.opencontainers.image.description="CAMARA API exposure layer for 5G Research Lab"

WORKDIR /app

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# API specs (OpenAPI YAML files from CAMARA project)
COPY api-specs/ ./api-specs/

# Application source
COPY src/ ./src/

EXPOSE 8080 8443

HEALTHCHECK --interval=10s --timeout=5s --retries=6 --start-period=20s \
  CMD curl -f http://localhost:8080/healthz || exit 1

CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "info"]
