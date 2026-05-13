#!/usr/bin/env bash
set -euo pipefail

echo "==> dbt $(dbt --version | head -1)"
dbt deps --target prod
dbt build --target prod
echo "==> dbt build completed successfully"
