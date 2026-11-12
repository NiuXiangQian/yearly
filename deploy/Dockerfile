ARG PYTHON_IMAGE=python:3.12-slim-bookworm
FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PYTHONPATH=/app/backend
WORKDIR /app
COPY backend/requirements.txt backend/requirements.txt
RUN pip install --no-cache-dir -r backend/requirements.txt
COPY backend backend
COPY REVISION REVISION
USER 10001:10001
CMD ["uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "18080", "--workers", "1", "--proxy-headers", "--forwarded-allow-ips=127.0.0.1", "--no-access-log"]
