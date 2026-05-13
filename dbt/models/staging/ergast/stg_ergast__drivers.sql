-- One row per driver.

with flat as (
    select
        driver.driverId          as driver_id,
        driver.code              as code,
        driver.permanentNumber   as permanent_number,
        driver.givenName         as given_name,
        driver.familyName        as family_name,
        driver.dateOfBirth       as date_of_birth,
        driver.nationality       as nationality,
        driver.url               as driver_url
    from {{ source('ergast', 'ergast_drivers') }} as page,
         unnest(page.DriverTable.Drivers) as driver
)

select distinct *
from flat
where driver_id is not null
