# dbt runner

Container image + entrypoint that packages the `dbt/` project for a Cloud Run Job. Runs `dbt deps && dbt build --target prod` on a daily schedule, 30 minutes after the Ergast extract has settled. Uses the attached `f1-dbt-sa` service account for BigQuery auth — no profiles.yml secrets in the image.

_Implementation lands in Phase 6._
