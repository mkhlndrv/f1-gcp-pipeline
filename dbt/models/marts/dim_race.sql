-- One row per race weekend. race_id is the surrogate key the fact joins on.

select
    concat(cast(season as string), '-', cast(round as string)) as race_id,
    season,
    round,
    race_name,
    circuit_id,
    circuit_name,
    country,
    race_date,
    race_url
from {{ ref('stg_ergast__races') }}
