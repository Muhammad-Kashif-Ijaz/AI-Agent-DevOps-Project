# syntax=docker/dockerfile:1.7

FROM python:3.12-slim AS wheels

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build
COPY requirements.txt ./
RUN python -m pip wheel --wheel-dir /wheels --requirement requirements.txt


FROM python:3.12-slim AS runtime

ARG KEIVO_UID=10001
ARG KEIVO_GID=10001

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    APP_ENV=production \
    AGENT_DATA_DIR=/app/data

RUN groupadd --gid "${KEIVO_GID}" keivo \
    && useradd --uid "${KEIVO_UID}" --gid keivo --create-home --home-dir /home/keivo --shell /usr/sbin/nologin keivo

WORKDIR /app
COPY requirements.txt ./
COPY --from=wheels /wheels /wheels
RUN python -m pip install --no-index --find-links=/wheels --requirement requirements.txt \
    && rm -rf /wheels

COPY --chown=keivo:keivo server.py ./server.py
COPY --chown=keivo:keivo static ./static
RUN mkdir -p /app/data && chown keivo:keivo /app/data

USER keivo:keivo
EXPOSE 8000

HEALTHCHECK --interval=20s --timeout=5s --start-period=20s --retries=5 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/status', timeout=3).read()"]

CMD ["python", "server.py", "--host", "0.0.0.0", "--port", "8000", "--no-open"]
