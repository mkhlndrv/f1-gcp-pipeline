# dbt-runner: containerised dbt build for daily Cloud Run Job execution.
# Build context = repo root (Dockerfile path: dbt_runner/Dockerfile).

FROM python:3.12-slim

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DBT_PROFILES_DIR=/root/.dbt

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

RUN pip install "dbt-bigquery==1.11.*"

WORKDIR /app
COPY dbt/ /app/dbt/
COPY dbt_runner/profiles.yml /root/.dbt/profiles.yml
COPY dbt_runner/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /app/dbt
ENTRYPOINT ["/entrypoint.sh"]
