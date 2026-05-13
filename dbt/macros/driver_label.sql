{# Map an OpenF1 driver_number to its 3-letter code. Tier-2 shortcut: hardcoded
   2026 grid + 2025 Abu Dhabi carry-over. Replace with dim_driver_xref once the
   /drivers extractor lands (Tier 3 follow-up). #}
{% macro driver_label(driver_number_col) -%}
case {{ driver_number_col }}
    when  1 then 'VER'  when  4 then 'NOR'  when  5 then 'BOR'
    when  6 then 'HAD'  when  7 then 'DOO'  when 10 then 'GAS'
    when 11 then 'PER'  when 12 then 'ANT'  when 14 then 'ALO'
    when 16 then 'LEC'  when 18 then 'STR'  when 20 then 'MAG'
    when 22 then 'TSU'  when 23 then 'ALB'  when 24 then 'ZHO'
    when 27 then 'HUL'  when 30 then 'LAW'  when 31 then 'OCO'
    when 43 then 'COL'  when 44 then 'HAM'  when 55 then 'SAI'
    when 63 then 'RUS'  when 77 then 'BOT'  when 81 then 'PIA'
    when 87 then 'BEA'
    else concat('#', cast({{ driver_number_col }} as string))
end
{%- endmacro %}

{% macro session_label(session_key_col) -%}
case {{ session_key_col }}
    when  9839 then '2025 Abu Dhabi GP'
    when 11234 then '2026 Australian GP'
    when 11240 then '2026 Chinese GP — Sprint'
    when 11245 then '2026 Chinese GP'
    when 11253 then '2026 Japanese GP'
    when 11261 then '2026 Bahrain GP'
    when 11269 then '2026 Saudi Arabian GP'
    when 11275 then '2026 Miami GP — Sprint'
    when 11280 then '2026 Miami GP'
    else concat('Session #', cast({{ session_key_col }} as string))
end
{%- endmacro %}
