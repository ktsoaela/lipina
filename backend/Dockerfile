# syntax=docker/dockerfile:1
FROM python:3.13-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
RUN useradd --create-home --uid 10001 lipina

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .
RUN DEBUG=0 SECRET_KEY=build-only-not-secret python manage.py collectstatic --noinput \
    && mkdir -p /data/media && chown -R lipina:lipina /data /app

USER lipina
ENV MEDIA_ROOT=/data/media
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=4).status == 200 else 1)"

ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["gunicorn", "config.wsgi:application", "--bind", "0.0.0.0:8000", "--workers", "3", "--threads", "4", \
     "--timeout", "120", "--access-logfile", "-", "--forwarded-allow-ips", "*"]
