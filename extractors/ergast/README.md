# Ergast extractor

Daily batch HTTP-triggered Cloud Run Function. Pulls F1 race-weekend data from the Jolpica/Ergast API and writes NDJSON to `gs://image-lab-f1-lake/raw/source=ergast/endpoint=*/dt=*/`.

_Implementation lands in Phase 2._
