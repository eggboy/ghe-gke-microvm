FROM python:3.12-alpine

WORKDIR /app
COPY server.py /app/server.py

ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=2s --timeout=2s --retries=5 \
  CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1

CMD ["python3", "/app/server.py"]
