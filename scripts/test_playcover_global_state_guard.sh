#!/bin/bash

# Source-only guard for PlayCover gates that can mutate account-global cache,
# Runtime HOME, or socket state. IOS_USE_HOME does not isolate those roots.

playcover_global_state_config_fail() {
  local label="$1"
  shift
  printf '[%s] EX_CONFIG: %s\n' "$label" "$*" >&2
  exit 78
}

playcover_require_disposable_account_contract() {
  local label="$1"
  local account_uid
  local account_name
  local account_record
  local account_home
  local canonical_account_home
  local expected_account_home
  local expected_global_cache
  local expected_runtime_root
  local expected_socket_root

  if [[ "$(uname -s)" != "Darwin" ]]; then
    playcover_global_state_config_fail \
      "$label" \
      "the disposable-account contract is supported only on macOS"
  fi

  account_uid="$(/usr/bin/id -u 2>/dev/null)" ||
    playcover_global_state_config_fail \
      "$label" \
      "could not resolve the effective account UID"
  account_name="$(/usr/bin/id -un 2>/dev/null)" ||
    playcover_global_state_config_fail \
      "$label" \
      "could not resolve the effective account name"
  if [[
    ! "$account_uid" =~ ^[0-9]+$ ||
    "$account_uid" -lt 501 ||
    -z "$account_name" ||
    "$account_name" == *$'\n'* ||
    "$account_name" == *$'\r'*
  ]]; then
    playcover_global_state_config_fail \
      "$label" \
      "a non-system disposable macOS account is required"
  fi

  account_record="$(
    /usr/bin/dscacheutil -q user -a uid "$account_uid" 2>/dev/null
  )" || playcover_global_state_config_fail \
    "$label" \
    "could not resolve the effective account record"
  account_home="$(
    printf '%s\n' "$account_record" |
      /usr/bin/awk '
        /^dir:[[:space:]]/ {
          sub(/^dir:[[:space:]]*/, "")
          print
          exit
        }
      '
  )"
  if [[
    "$account_home" != /* ||
    "$account_home" == "/" ||
    "$account_home" == "/var/empty" ||
    "$account_home" == *$'\n'* ||
    "$account_home" == *$'\r'* ||
    ! -d "$account_home"
  ]]; then
    playcover_global_state_config_fail \
      "$label" \
      "the effective account has no usable absolute login home"
  fi
  canonical_account_home="$(
    cd "$account_home" 2>/dev/null && /bin/pwd -P
  )" || playcover_global_state_config_fail \
    "$label" \
    "could not canonicalize the effective account home"

  expected_account_home="$canonical_account_home"
  expected_global_cache="$canonical_account_home/Library/Caches/dev.ios-use/mac/prepared-v1"
  expected_runtime_root="$canonical_account_home/Library/Application Support/dev.ios-use/mac/runtime-homes"
  expected_socket_root="/private/tmp/dev.ios-use-$account_uid"

  if [[
    "${IOS_USE_PLAYCOVER_DISPOSABLE_ACCOUNT_ACK:-}" != "I_UNDERSTAND_THIS_ACCOUNT_IS_DISPOSABLE"
  ]]; then
    playcover_global_state_config_fail \
      "$label" \
      "set IOS_USE_PLAYCOVER_DISPOSABLE_ACCOUNT_ACK=I_UNDERSTAND_THIS_ACCOUNT_IS_DISPOSABLE only in a disposable macOS account"
  fi
  if [[
    "${IOS_USE_PLAYCOVER_EXPECTED_ACCOUNT_HOME:-}" != "$expected_account_home"
  ]]; then
    playcover_global_state_config_fail \
      "$label" \
      "IOS_USE_PLAYCOVER_EXPECTED_ACCOUNT_HOME does not match the canonical login-account home"
  fi
  PLAYCOVER_ACCOUNT_UID="$account_uid"
  PLAYCOVER_ACCOUNT_HOME="$expected_account_home"
  PLAYCOVER_GLOBAL_CACHE_ROOT="$expected_global_cache"
  PLAYCOVER_GLOBAL_OBJECTS_ROOT="$expected_global_cache/objects"
  PLAYCOVER_GLOBAL_HOMES_ROOT="$expected_global_cache/homes"
  PLAYCOVER_GLOBAL_LOCKS_ROOT="$expected_global_cache/locks"
  PLAYCOVER_RUNTIME_ROOT="$expected_runtime_root"
  PLAYCOVER_SOCKET_ROOT="$expected_socket_root"
  export \
    PLAYCOVER_ACCOUNT_UID \
    PLAYCOVER_ACCOUNT_HOME \
    PLAYCOVER_GLOBAL_CACHE_ROOT \
    PLAYCOVER_GLOBAL_OBJECTS_ROOT \
    PLAYCOVER_GLOBAL_HOMES_ROOT \
    PLAYCOVER_GLOBAL_LOCKS_ROOT \
    PLAYCOVER_RUNTIME_ROOT \
    PLAYCOVER_SOCKET_ROOT
}
