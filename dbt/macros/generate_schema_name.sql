{# Override default to use the configured schema literally (no prefix).
   With this macro: +schema: staging → dataset `f1_staging` (NOT `<target>_staging`). #}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        f1_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
