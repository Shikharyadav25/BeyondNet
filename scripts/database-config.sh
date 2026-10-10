#!/usr/bin/env bash
# Shared configuration reader. Never print passwords or evaluate configuration as shell code.
bank_config_value() {
  local bank_field="$1" bank_env="$2" bank_fallback="$3" bank_value
  if [ -n "${!bank_env:-}" ]; then printf '%s' "${!bank_env}"; return; fi
  bank_value=""
  if [ -f "${BEYONDNET_DB_CONFIG:-$PWD/data/postgres.properties}" ]; then
    bank_value="$(sed -n "s/^${bank_field}=//p" "${BEYONDNET_DB_CONFIG:-$PWD/data/postgres.properties}" | head -n 1 | tr -d '\r')"
  fi
  printf '%s' "${bank_value:-$bank_fallback}"
}
bank_database_is_local() {
  local bank_url
  bank_url="$(bank_config_value url BEYONDNET_DB_URL 'jdbc:postgresql://127.0.0.1:5433/beyondnet')"
  case "$bank_url" in
    jdbc:postgresql://127.0.0.1:*|jdbc:postgresql://127.0.0.1/*|jdbc:postgresql://localhost:*|jdbc:postgresql://localhost/*|jdbc:postgresql://\[::1\]:*|jdbc:postgresql://\[::1\]/*) return 0 ;;
    *) return 1 ;;
  esac
}
