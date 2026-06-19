timestamp_ms() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

time_command_ms() {
  local result_var="$1"
  local start_ms=0
  local end_ms=0
  local elapsed_ms=0
  local command_status=0

  shift

  start_ms="$(timestamp_ms)" || return 1

  set +e
  "$@"
  command_status=$?
  set -e

  end_ms="$(timestamp_ms)" || return 1
  elapsed_ms=$((end_ms - start_ms))
  printf -v "$result_var" '%s' "$elapsed_ms"

  return "$command_status"
}

assert_duration_at_least_ms() {
  local description="$1"
  local actual_ms="$2"
  local minimum_ms="$3"

  if [ "$actual_ms" -ge "$minimum_ms" ]; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_duration_under_ms() {
  local description="$1"
  local actual_ms="$2"
  local maximum_ms="$3"

  if [ "$actual_ms" -lt "$maximum_ms" ]; then
    pass "$description"
  else
    fail "$description"
  fi
}