FROM python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0

WORKDIR /app
COPY origin/server.py /app/server.py
COPY fixtures/fixture.bin /fixtures/fixture.bin

EXPOSE 8080
CMD ["python3", "/app/server.py"]
