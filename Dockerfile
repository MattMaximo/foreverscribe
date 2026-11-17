# ForeverScribe relay (relay/app.py): the hosted mailbox for the `relay` transport. docs/RELAY.md.
# DigitalOcean App Platform finds this file when you create an app from this repository. Only relay/ is copied in:
# the companion itself never runs here. Run exactly one container (blobs live on its local disk).
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080 RELAY_DATA_DIR=/tmp/relay-data
WORKDIR /app
COPY relay/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt && useradd --system --uid 10001 relay
COPY relay/app.py /app/app.py
USER relay
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request,os; urllib.request.urlopen('http://127.0.0.1:%s/v1/health' % os.environ.get('PORT','8080'), timeout=4)"
CMD ["sh", "-c", "exec uvicorn app:app --host 0.0.0.0 --port ${PORT} --workers 1 --no-access-log --no-proxy-headers --limit-concurrency 200"]
