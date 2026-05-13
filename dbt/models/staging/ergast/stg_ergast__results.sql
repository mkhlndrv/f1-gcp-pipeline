-- One row per (season, round, driver). Same row appears in every page-load → DISTINCT collapses dupes.

with flat as (
    select
        race.season                       as season,
        race.round                        as round,
        result.Driver.driverId            as driver_id,
        result.Constructor.constructorId  as constructor_id,
        result.position                   as position,
        result.grid                       as grid,
        result.points                     as points,
        result.laps                       as laps,
        result.status                     as status
    from {{ source('ergast', 'ergast_results') }} as page,
         unnest(page.RaceTable.Races)     as race,
         unnest(race.Results)             as result
)

select distinct *
from flat
where season is not null
  and round is not null
  and driver_id is not null
