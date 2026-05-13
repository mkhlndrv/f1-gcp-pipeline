-- One row per driver. Joins driver biographical info to their latest constructor.

with latest_team as (
    select
        driver_id,
        constructor_id
    from {{ ref('stg_ergast__results') }}
    qualify row_number() over (partition by driver_id order by season desc, round desc) = 1
)

select
    d.driver_id,
    d.code,
    d.permanent_number,
    d.given_name,
    d.family_name,
    concat(d.given_name, ' ', d.family_name) as full_name,
    d.date_of_birth,
    d.nationality,
    t.constructor_id as latest_constructor_id
from {{ ref('stg_ergast__drivers') }} d
left join latest_team t
       on t.driver_id = d.driver_id
