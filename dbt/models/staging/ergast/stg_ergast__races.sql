-- One row per race weekend. Source: ergast_results (each MRData page contains the season's races + per-race results).
-- Same race appears in every page-load, so we DISTINCT to collapse duplicates.

with flat as (
    select
        race.season                    as season,
        race.round                     as round,
        race.raceName                  as race_name,
        race.date                      as race_date,
        race.Circuit.circuitId         as circuit_id,
        race.Circuit.circuitName       as circuit_name,
        race.Circuit.Location.country  as country,
        race.url                       as race_url
    from {{ source('ergast', 'ergast_results') }} as page,
         unnest(page.RaceTable.Races)  as race
)

select distinct *
from flat
where season is not null
  and round is not null
