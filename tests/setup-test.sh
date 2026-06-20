#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SETUP_SCRIPT="$ROOT_DIR/scripts/setup.sh"
LOCAL_CONFIG_PATH="$ROOT_DIR/vm/runtime/openclaw.json"

FAILURES=0
RUN1_OUTPUT=""
RUN2_OUTPUT=""
DIFF_OUTPUT=""
EXISTING_OUTPUT=""
EXISTING_MANAGED_BLOCKED_OUTPUT=""
OWNED_RESTART_OUTPUT=""
STALE_OPENCLAW_OUTPUT=""
EXTERNAL_RERUN_OUTPUT=""
ENV_BACKUP=""
SYSTEM_TEST_ROOT=""
MOCK_BIN_DIR=""
LLAMA_INSTALL_MODE=""
LLAMA_WRAPPER_PATH=""
LLAMA_ENV_PATH=""
LLAMA_PLIST_PATH=""
LLAMA_API_STATE_FILE=""
LLAMA_OWNED_STATE_FILE=""
LAUNCHCTL_LOG=""
PKILL_LOG=""
REMOTE_HOME=""
LLAMA_OWNER_FILE=""
LLAMA_PARENT_COMMAND_FILE=""
LLAMA_LISTENER_PID_FILE=""
OPENCLAW_SERVICE_STATE_FILE=""
TEST_VM_IP='192.168.64.2'
TEST_VM_USER='tester'
TEST_HOST_IP='127.0.0.1'
TEST_LLAMA_PORT=''

write_mock_command() {
  local name="$1"
  local content="$2"

  printf '%s\n' "$content" > "$MOCK_BIN_DIR/$name"
  chmod +x "$MOCK_BIN_DIR/$name"
}

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

show_captured_output() {
  local label="$1"
  local file_path="$2"

  if [ -n "$file_path" ] && [ -f "$file_path" ]; then
    printf -- '--- %s ---\n' "$label"
    cat "$file_path"
    printf -- '--- end %s ---\n' "$label"
  fi
}

cleanup() {
  if [ -n "$LLAMA_LISTENER_PID_FILE" ] && [ -f "$LLAMA_LISTENER_PID_FILE" ]; then
    kill "$(cat "$LLAMA_LISTENER_PID_FILE")" >/dev/null 2>&1 || true
    rm -f "$LLAMA_LISTENER_PID_FILE"
  fi

  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    cp "$ENV_BACKUP" "$ENV_FILE"
    rm -f "$ENV_BACKUP"
  fi

  rm -f "$RUN1_OUTPUT" "$RUN2_OUTPUT" "$DIFF_OUTPUT" "$EXISTING_OUTPUT" "$EXISTING_MANAGED_BLOCKED_OUTPUT" "$OWNED_RESTART_OUTPUT" "$STALE_OPENCLAW_OUTPUT" "$EXTERNAL_RERUN_OUTPUT"

  if [ -n "$SYSTEM_TEST_ROOT" ] && [ -d "$SYSTEM_TEST_ROOT" ]; then
    rm -rf "$SYSTEM_TEST_ROOT"
  fi
}

trap cleanup EXIT

require_var() {
  local name="$1"

  if [ -n "${!name:-}" ]; then
    pass "$name is set"
  else
    fail "$name is not set"
  fi
}

configure_test_llama_paths() {
  export CLAWBOX_LLAMA_WRAPPER_DEST="$SYSTEM_TEST_ROOT/usr/local/bin/clawbox-llama-wrapper.sh"
  export CLAWBOX_LLAMA_ENV_DEST="$SYSTEM_TEST_ROOT/usr/local/etc/clawbox.env"
  export CLAWBOX_LLAMA_PLIST_DEST="$SYSTEM_TEST_ROOT/Library/LaunchDaemons/com.clawbox.llama.plist"
  export CLAWBOX_LLAMA_OUT_LOG="$SYSTEM_TEST_ROOT/logs/runtime/clawbox-llama-system.out.log"
  export CLAWBOX_LLAMA_ERR_LOG="$SYSTEM_TEST_ROOT/logs/runtime/clawbox-llama-system.err.log"

  export CLAWBOX_LLAMA_USER_WRAPPER_DEST="$SYSTEM_TEST_ROOT/user/Library/Application Support/ClawBox/bin/clawbox-llama-wrapper.sh"
  export CLAWBOX_LLAMA_USER_ENV_DEST="$SYSTEM_TEST_ROOT/user/Library/Application Support/ClawBox/clawbox.env"
  export CLAWBOX_LLAMA_USER_PLIST_DEST="$SYSTEM_TEST_ROOT/user/Library/LaunchAgents/com.clawbox.llama.plist"
  export CLAWBOX_LLAMA_USER_OUT_LOG="$SYSTEM_TEST_ROOT/logs/runtime/clawbox-llama-user.out.log"
  export CLAWBOX_LLAMA_USER_ERR_LOG="$SYSTEM_TEST_ROOT/logs/runtime/clawbox-llama-user.err.log"

  export CLAWBOX_VM_AUTOSTART_OUT_LOG="$SYSTEM_TEST_ROOT/logs/vm/clawbox-startutmvm.out.log"
  export CLAWBOX_VM_AUTOSTART_ERR_LOG="$SYSTEM_TEST_ROOT/logs/vm/clawbox-startutmvm.err.log"
}

detect_test_llama_install_mode() {
  local status=0

  BASE_DIR="$ROOT_DIR"
  configure_test_llama_paths

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_capture_status detect_existing_llama_install_mode
  status=$LLAMA_LAST_STATUS

  if [ "$status" -ne 0 ] || [ -z "${REPLY:-}" ]; then
    return 1
  fi

  LLAMA_INSTALL_MODE="$REPLY"
  LLAMA_WRAPPER_PATH="$(llama_mode_wrapper_dest "$LLAMA_INSTALL_MODE")"
  LLAMA_ENV_PATH="$(llama_mode_env_dest "$LLAMA_INSTALL_MODE")"
  LLAMA_PLIST_PATH="$(llama_mode_plist_dest "$LLAMA_INSTALL_MODE")"
  return 0
}

validate_llama_artifacts_for_mode() {
  if [ "$LLAMA_INSTALL_MODE" = 'user' ]; then
    if [ -x "$LLAMA_WRAPPER_PATH" ]; then
      pass "user llama wrapper is installed"
    else
      fail "user llama wrapper is not installed"
    fi

    if [ -f "$LLAMA_PLIST_PATH" ]; then
      pass "user llama LaunchAgent plist is installed"
    else
      fail "user llama LaunchAgent plist is not installed"
    fi
  else
    if [ -x "$LLAMA_WRAPPER_PATH" ]; then
      pass "system llama wrapper is installed"
    else
      fail "system llama wrapper is not installed"
    fi

    if [ -f "$LLAMA_PLIST_PATH" ]; then
      pass "system llama LaunchDaemon plist is installed"
    else
      fail "system llama LaunchDaemon plist is not installed"
    fi
  fi

  if [ -f "$LLAMA_ENV_PATH" ] \
    && grep -Fq 'LLAMA_BIN=' "$LLAMA_ENV_PATH" \
    && grep -Fq 'MODEL_PATH=' "$LLAMA_ENV_PATH" \
    && grep -Fq 'LLAMA_HOST=' "$LLAMA_ENV_PATH" \
    && grep -Fq 'LLAMA_PORT=' "$LLAMA_ENV_PATH" \
    && grep -Fq 'LLAMA_CTX=' "$LLAMA_ENV_PATH" \
    && ! grep -Fq 'LLAMA_BASE_URL=' "$LLAMA_ENV_PATH"; then
    pass "$LLAMA_INSTALL_MODE llama runtime env file contains only runtime values"
  else
    fail "$LLAMA_INSTALL_MODE llama runtime env file does not contain the expected runtime values"
  fi
}

run_setup() {
  local output_file="$1"
  local status

  set +e
  (
    cd "$ROOT_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"
    configure_test_llama_paths
    printf '\n\n\n\n\n\n\n\n\n\n\n\n' | ./scripts/setup.sh
  ) >"$output_file" 2>&1
  status=$?
  set -e

  return "$status"
}

run_setup_with_decline() {
  local output_file="$1"
  local status

  set +e
  (
    cd "$ROOT_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"
    configure_test_llama_paths
    printf '\n\n\n\n\n\n\nn\n\n\n\n\n' | ./scripts/setup.sh
  ) >"$output_file" 2>&1
  status=$?
  set -e

  return "$status"
}

run_setup_with_input() {
  local output_file="$1"
  local input_text="$2"
  local status

  set +e
  (
    cd "$ROOT_DIR"
    export PATH="$MOCK_BIN_DIR:$PATH"
    configure_test_llama_paths
    printf '%b' "$input_text" | ./scripts/setup.sh
  ) >"$output_file" 2>&1
  status=$?
  set -e

  return "$status"
}

reset_mock_llama_state() {
  if [ -n "$LLAMA_LISTENER_PID_FILE" ] && [ -f "$LLAMA_LISTENER_PID_FILE" ]; then
    kill "$(cat "$LLAMA_LISTENER_PID_FILE")" >/dev/null 2>&1 || true
    rm -f "$LLAMA_LISTENER_PID_FILE"
  fi

  rm -f "$LLAMA_API_STATE_FILE" "$LLAMA_OWNED_STATE_FILE" "$LLAMA_OWNER_FILE" "$LLAMA_PARENT_COMMAND_FILE" "$LAUNCHCTL_LOG" "$PKILL_LOG" "$OPENCLAW_SERVICE_STATE_FILE"
  rm -rf "$SYSTEM_TEST_ROOT/usr" "$SYSTEM_TEST_ROOT/Library" "$SYSTEM_TEST_ROOT/user"
}

reset_remote_config() {
  ssh "$VM_HOST" 'mkdir -p ~/.openclaw' >/dev/null 2>&1
  scp -O -q "$LOCAL_CONFIG_PATH" "$VM_HOST:~/.openclaw/openclaw.json" >/dev/null 2>&1
}

set_env_value() {
  local key="$1"
  local value="$2"
  local temp_file

  temp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    $0 ~ ("^" key "=") {
      print key "=\"" value "\""
      next
    }

    { print }
  ' "$ENV_FILE" >"$temp_file"
  mv "$temp_file" "$ENV_FILE"
}

reserve_test_llama_port() {
  if [ -n "$TEST_LLAMA_PORT" ]; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    TEST_LLAMA_PORT="$(python3 -c 'import socket; sock = socket.socket(); sock.bind(("127.0.0.1", 0)); print(sock.getsockname()[1]); sock.close()')"
  fi

  if [ -z "$TEST_LLAMA_PORT" ]; then
    TEST_LLAMA_PORT='11434'
  fi
}

prepare_test_env() {
  local model_path="$SYSTEM_TEST_ROOT/models/test-model.gguf"
  local llama_bin="$SYSTEM_TEST_ROOT/bin/llama-server"
  local remote_openclaw_bin="$REMOTE_HOME/.local/bin/openclaw"

  reserve_test_llama_port

  mkdir -p "$SYSTEM_TEST_ROOT/models" "$SYSTEM_TEST_ROOT/bin"
  : > "$model_path"
  printf '#!/bin/bash\nexit 0\n' > "$llama_bin"
  chmod +x "$llama_bin"
  mkdir -p "$REMOTE_HOME/.local/bin"
  printf '#!/bin/bash\nif [ "${1:-}" = "--version" ]; then\n  printf "openclaw test\\n"\nfi\nexit 0\n' > "$remote_openclaw_bin"
  chmod +x "$remote_openclaw_bin"
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$REMOTE_HOME/.zprofile"

  cp "$ENV_BACKUP" "$ENV_FILE"
  set_env_value HOST_IP "$TEST_HOST_IP"
  set_env_value VM_IP "$TEST_VM_IP"
  set_env_value VM_USER "$TEST_VM_USER"
  set_env_value VM_USER_PATH "$REMOTE_HOME/Users/$TEST_VM_USER"
  set_env_value VM_HOST "$TEST_VM_USER@$TEST_VM_IP"
  set_env_value VM_RUNTIME_PATH "$REMOTE_HOME/Users/$TEST_VM_USER/ClawBox"
  set_env_value VM_MACHINE_NAME 'ClawBox Test VM'
  set_env_value LLAMA_BIN "$llama_bin"
  set_env_value LLAMA_HOST '0.0.0.0'
  set_env_value LLAMA_PORT "$TEST_LLAMA_PORT"
  set_env_value LLAMA_CTX '16384'
  set_env_value LLAMA_BASE_URL "http://$TEST_HOST_IP:$TEST_LLAMA_PORT/v1"
  set_env_value MODEL_PATH "$model_path"
  set_env_value FIREWALL_SHARED_SUBNET '192.168.64.0/24'
  set_env_value OPENCLAW_PROVIDER_NAME 'clawbox'
  set_env_value OPENCLAW_DEFAULT_MODEL 'test-model'
  set_env_value OPENCLAW_AUTOSTART 'false'

  refresh_test_env_exports

  mkdir -p "$VM_RUNTIME_PATH" "$REMOTE_HOME/.openclaw"
}

refresh_test_env_exports() {

  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a

  export SETUP_TEST_HOST_IP="$HOST_IP"
  export SETUP_TEST_LLAMA_BIN="$LLAMA_BIN"
  export SETUP_TEST_LLAMA_PORT="$LLAMA_PORT"
  export SETUP_TEST_VM_HOST="$VM_HOST"
  export SETUP_TEST_REMOTE_HOME="$REMOTE_HOME"
  export SETUP_TEST_MOCK_BIN_DIR="$MOCK_BIN_DIR"
  export SETUP_TEST_LLAMA_API_STATE_FILE="$LLAMA_API_STATE_FILE"
  export SETUP_TEST_LLAMA_OWNER_FILE="$LLAMA_OWNER_FILE"
  export SETUP_TEST_LLAMA_PARENT_COMMAND_FILE="$LLAMA_PARENT_COMMAND_FILE"
  export SETUP_TEST_LLAMA_OWNED_STATE_FILE="$LLAMA_OWNED_STATE_FILE"
  export SETUP_TEST_LLAMA_LISTENER_PID_FILE="$LLAMA_LISTENER_PID_FILE"
  export SETUP_TEST_OPENCLAW_SERVICE_STATE_FILE="$OPENCLAW_SERVICE_STATE_FILE"
  export SETUP_TEST_LAUNCHCTL_LOG="$LAUNCHCTL_LOG"
  export SETUP_TEST_PKILL_LOG="$PKILL_LOG"
  unset SETUP_TEST_EXTERNAL_LLAMA_MODELS_URL
  unset SETUP_TEST_EXTERNAL_LLAMA_READY_FILE
  unset SETUP_TEST_DEFAULT_LLAMA_MODELS_READY_FILE
  unset SETUP_TEST_LLAMA_LAUNCHD_STATE_FILE
  unset SETUP_TEST_USE_REAL_NETSTAT
}

set_mock_llama_instance() {
  local owner="$1"
  local parent_command="$2"

  touch "$LLAMA_API_STATE_FILE"
  printf '%s\n' "$owner" > "$LLAMA_OWNER_FILE"
  printf '%s\n' "$parent_command" > "$LLAMA_PARENT_COMMAND_FILE"
}

printf 'Running setup tests\n'

if command -v bash >/dev/null 2>&1; then
  pass "bash is available"
else
  fail "bash is not available"
fi

if command -v ssh >/dev/null 2>&1; then
  pass "ssh is available"
else
  fail "ssh is not available"
fi

if [ -x "$SETUP_SCRIPT" ]; then
  pass "setup.sh is executable"
else
  fail "setup.sh is not executable"
fi

if [ -f "$ENV_FILE" ]; then
  pass ".env exists"
else
  fail ".env is missing"
fi

if [ -f "$ENV_FILE" ] && bash -n "$ENV_FILE" >/dev/null 2>&1; then
  pass ".env parses successfully"
else
  fail ".env does not parse successfully"
fi

RUN1_OUTPUT="$(mktemp)"
RUN2_OUTPUT="$(mktemp)"
DIFF_OUTPUT="$(mktemp)"
EXISTING_OUTPUT="$(mktemp)"
EXISTING_MANAGED_BLOCKED_OUTPUT="$(mktemp)"
OWNED_RESTART_OUTPUT="$(mktemp)"
STALE_OPENCLAW_OUTPUT="$(mktemp)"
EXTERNAL_RERUN_OUTPUT="$(mktemp)"
ENV_BACKUP="$(mktemp)"
SYSTEM_TEST_ROOT="$(mktemp -d)"
MOCK_BIN_DIR="$SYSTEM_TEST_ROOT/mock-bin"
LLAMA_API_STATE_FILE="$SYSTEM_TEST_ROOT/llama-api-ready"
LLAMA_OWNED_STATE_FILE="$SYSTEM_TEST_ROOT/llama-owned"
LLAMA_OWNER_FILE="$SYSTEM_TEST_ROOT/llama-owner"
LLAMA_PARENT_COMMAND_FILE="$SYSTEM_TEST_ROOT/llama-parent-command"
LLAMA_LISTENER_PID_FILE="$SYSTEM_TEST_ROOT/llama-listener.pid"
OPENCLAW_SERVICE_STATE_FILE="$SYSTEM_TEST_ROOT/openclaw-service-state"
LAUNCHCTL_LOG="$SYSTEM_TEST_ROOT/logs/tests/launchctl.log"
PKILL_LOG="$SYSTEM_TEST_ROOT/logs/tests/pkill.log"
REMOTE_HOME="$SYSTEM_TEST_ROOT/remote-home"
cp "$ENV_FILE" "$ENV_BACKUP"

mkdir -p "$MOCK_BIN_DIR"
mkdir -p "$SYSTEM_TEST_ROOT/logs/tests" "$REMOTE_HOME"

prepare_test_env

require_var VM_HOST
require_var VM_RUNTIME_PATH

write_mock_command sudo '#!/bin/bash
exit 1'

write_mock_command install '#!/bin/bash
set -e
mode=""
if [ "${1:-}" = "-m" ]; then
  mode="$2"
  shift 2
fi
mkdir -p "$(dirname "$2")"
cp "$1" "$2"
if [ -n "$mode" ]; then
  chmod "$mode" "$2"
fi'

write_mock_command chown '#!/bin/bash
exit 0'

write_mock_command launchctl '#!/bin/bash
printf "%s\n" "$*" >> "$SETUP_TEST_LAUNCHCTL_LOG"

start_llama_listener() {
  if [ -f "$SETUP_TEST_LLAMA_LISTENER_PID_FILE" ] && kill -0 "$(cat "$SETUP_TEST_LLAMA_LISTENER_PID_FILE")" >/dev/null 2>&1; then
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || return 1
  python3 -m http.server "$SETUP_TEST_LLAMA_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
  printf "%s\n" "$!" > "$SETUP_TEST_LLAMA_LISTENER_PID_FILE"
}

stop_llama_listener() {
  if [ -f "$SETUP_TEST_LLAMA_LISTENER_PID_FILE" ]; then
    kill "$(cat "$SETUP_TEST_LLAMA_LISTENER_PID_FILE")" >/dev/null 2>&1 || true
    rm -f "$SETUP_TEST_LLAMA_LISTENER_PID_FILE"
  fi
}

case "${1:-}" in
  bootstrap|kickstart)
    case " $* " in
      *"com.clawbox.llama.plist "*|*"com.clawbox.llama "*)
        touch "$SETUP_TEST_LLAMA_API_STATE_FILE" "$SETUP_TEST_LLAMA_OWNED_STATE_FILE"
        printf "%s\n" "$(id -un 2>/dev/null || echo tester)" > "$SETUP_TEST_LLAMA_OWNER_FILE"
        printf "%s\n" launchd > "$SETUP_TEST_LLAMA_PARENT_COMMAND_FILE"
        start_llama_listener || exit 1
        exit 0
        ;;
      *" com.clawbox.openclaw.plist "*|*" com.clawbox.openclaw "*)
        touch "$SETUP_TEST_OPENCLAW_SERVICE_STATE_FILE"
        exit 0
        ;;
    esac
    ;;
  bootout)
    case " $* " in
      *"com.clawbox.llama.plist "*|*"com.clawbox.llama "*)
        rm -f "$SETUP_TEST_LLAMA_API_STATE_FILE" "$SETUP_TEST_LLAMA_OWNED_STATE_FILE"
        stop_llama_listener
        exit 0
        ;;
      *" com.clawbox.openclaw.plist "*|*" com.clawbox.openclaw "*)
        rm -f "$SETUP_TEST_OPENCLAW_SERVICE_STATE_FILE"
        exit 0
        ;;
    esac
    ;;
  print)
    case " $* " in
      *"com.clawbox.llama "*)
        launchd_state_file="${SETUP_TEST_LLAMA_LAUNCHD_STATE_FILE:-$SETUP_TEST_LLAMA_API_STATE_FILE}"
        [ -f "$launchd_state_file" ]
        exit $?
        ;;
      *" com.clawbox.openclaw "*)
        [ -f "$SETUP_TEST_OPENCLAW_SERVICE_STATE_FILE" ]
        exit $?
        ;;
    esac
      exit 1
    ;;
esac

    exit 0'

write_mock_command pgrep "#!/bin/bash
if [ -f \"$LLAMA_OWNED_STATE_FILE\" ]; then
  exit 0
fi
exit 1"

write_mock_command pkill '#!/bin/bash
printf "%s\n" "$*" >> "$SETUP_TEST_PKILL_LOG"
rm -f "$SETUP_TEST_LLAMA_API_STATE_FILE" "$SETUP_TEST_LLAMA_OWNED_STATE_FILE" "$SETUP_TEST_LLAMA_OWNER_FILE" "$SETUP_TEST_LLAMA_PARENT_COMMAND_FILE"
if [ -f "$SETUP_TEST_LLAMA_LISTENER_PID_FILE" ]; then
  kill "$(cat "$SETUP_TEST_LLAMA_LISTENER_PID_FILE")" >/dev/null 2>&1 || true
  rm -f "$SETUP_TEST_LLAMA_LISTENER_PID_FILE"
fi
exit 0'

write_mock_command curl '#!/bin/bash
url="${!#:-}"
default_models_url="http://${SETUP_TEST_HOST_IP:-127.0.0.1}:${SETUP_TEST_LLAMA_PORT:-11434}/v1/models"
external_models_url="${SETUP_TEST_EXTERNAL_LLAMA_MODELS_URL:-}"
external_ready_file="${SETUP_TEST_EXTERNAL_LLAMA_READY_FILE:-$SETUP_TEST_LLAMA_API_STATE_FILE}"
default_ready_file="${SETUP_TEST_DEFAULT_LLAMA_MODELS_READY_FILE:-$SETUP_TEST_LLAMA_API_STATE_FILE}"

if [ -n "$external_models_url" ] && [ "$url" = "$external_models_url" ] && [ -f "$external_ready_file" ]; then
  printf "%s\n" "{\"data\":[]}"
  exit 0
fi

if [ "$url" = "$default_models_url" ] && [ -f "$default_ready_file" ]; then
  printf "%s\n" "{\"data\":[]}"
  exit 0
fi

exit 1'

write_mock_command netstat '#!/bin/bash
if [ "${SETUP_TEST_USE_REAL_NETSTAT:-false}" = "true" ]; then
  exec /usr/sbin/netstat "$@"
fi
if [ -f "$SETUP_TEST_LLAMA_API_STATE_FILE" ]; then
  printf "tcp4       0      0  127.0.0.1:%s        *.*                    LISTEN\n" "${SETUP_TEST_LLAMA_PORT:-11434}"
fi
exit 0'

write_mock_command lsof '#!/bin/bash
if [ -f "$SETUP_TEST_LLAMA_API_STATE_FILE" ]; then
  case " $* " in
    *" -t "*)
      printf "%s\n" 4242
      ;;
    *)
      printf "COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n"
      printf "llama-ser 4242 %s    5u  IPv4 0x0  0t0  TCP 127.0.0.1:%s (LISTEN)\n" "$(cat "$SETUP_TEST_LLAMA_OWNER_FILE" 2>/dev/null || id -un 2>/dev/null || echo tester)" "${SETUP_TEST_LLAMA_PORT:-11434}"
      ;;
  esac
  exit 0
fi
exit 1'

write_mock_command ps '#!/bin/bash
if [ "${1:-}" = "-o" ] && [ "${3:-}" = "-p" ] && [ "${4:-}" = "4242" ]; then
  case "${2:-}" in
    user=)
      cat "$SETUP_TEST_LLAMA_OWNER_FILE"
      exit 0
      ;;
    ppid=)
      printf "%s\n" 1
      exit 0
      ;;
    command=)
      printf "%s --port %s\n" "${SETUP_TEST_LLAMA_BIN:-llama-server}" "${SETUP_TEST_LLAMA_PORT:-11434}"
      exit 0
      ;;
    stat=)
      printf "%s\n" S
      exit 0
      ;;
  esac
fi
if [ "${1:-}" = "-o" ] && [ "${3:-}" = "-p" ] && [ "${4:-}" = "1" ] && [ "${2:-}" = "command=" ]; then
  cat "$SETUP_TEST_LLAMA_PARENT_COMMAND_FILE"
  exit 0
fi
if [ "${1:-}" = "-axo" ] && [ "${2:-}" = "pid=,command=" ]; then
  if [ -f "$SETUP_TEST_LLAMA_API_STATE_FILE" ]; then
    printf "4242 %s --port %s\n" "${SETUP_TEST_LLAMA_BIN:-llama-server}" "${SETUP_TEST_LLAMA_PORT:-11434}"
  fi
  exit 0
fi
if [ "${1:-}" = "-axo" ] && [ "${2:-}" = "pid=,comm=,args=" ]; then
  exit 0
fi
exec /bin/ps "$@"'

write_mock_command openclaw '#!/bin/bash
if [ "${1:-}" = "--version" ]; then
  printf "openclaw test\n"
fi
exit 0'

write_mock_command ssh '#!/bin/bash
set -e
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n)
      shift
      ;;
    -o)
      shift 2
      ;;
    *)
      break
      ;;
  esac
done
if [ "$#" -eq 0 ]; then
  exit 0
fi
if [ "${1:-}" = "${SETUP_TEST_VM_HOST:-}" ]; then
  shift
fi
if [ "$#" -eq 0 ]; then
  exit 0
fi
HOME="$SETUP_TEST_REMOTE_HOME" PATH="$SETUP_TEST_REMOTE_HOME/.local/bin:$SETUP_TEST_MOCK_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" bash -c "$1"'

write_mock_command scp '#!/bin/bash
set -e
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q|-O)
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
src="${args[0]:-}"
dest="${args[1]:-}"
case "$dest" in
  *:*)
    dest="${dest#*:}"
    case "$dest" in
      ~/*)
        dest_path="$SETUP_TEST_REMOTE_HOME/${dest#~/}"
        ;;
      /*)
        dest_path="$dest"
        ;;
      *)
        dest_path="$SETUP_TEST_REMOTE_HOME/$dest"
        ;;
    esac
    mkdir -p "$(dirname "$dest_path")"
    cp "$src" "$dest_path"
    ;;
  *)
    exit 1
    ;;
esac'

export PATH="$MOCK_BIN_DIR:$PATH"

reset_mock_llama_state

prepare_test_env
set_env_value LLAMA_PORT '19090'
set_env_value LLAMA_BASE_URL 'http://host.internal:19090/custom/v1'
set_env_value LLAMA_EXTERNAL 'true'
refresh_test_env_exports

touch "$LLAMA_API_STATE_FILE"
printf '%s\n' 'otheruser' > "$LLAMA_OWNER_FILE"
printf '%s\n' 'login -pfl otheruser /bin/zsh' > "$LLAMA_PARENT_COMMAND_FILE"
export SETUP_TEST_EXTERNAL_LLAMA_MODELS_URL='http://host.internal:19090/custom/v1/models'
export SETUP_TEST_EXTERNAL_LLAMA_READY_FILE="$LLAMA_API_STATE_FILE"
export SETUP_TEST_DEFAULT_LLAMA_MODELS_READY_FILE="$SYSTEM_TEST_ROOT/default-llama-models-ready"
export SETUP_TEST_LLAMA_LAUNCHD_STATE_FILE="$SYSTEM_TEST_ROOT/external-launchd-state"
export SETUP_TEST_USE_REAL_NETSTAT='true'

if command -v python3 >/dev/null 2>&1; then
  python3 -m http.server "$SETUP_TEST_LLAMA_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$LLAMA_LISTENER_PID_FILE"
fi

if run_setup_with_input "$EXTERNAL_RERUN_OUTPUT" '2\n'; then
  pass "setup.sh reuses the configured external llama endpoint on a second run"
else
  show_captured_output 'external rerun output' "$EXTERNAL_RERUN_OUTPUT"
  fail "setup.sh should reuse the configured external llama endpoint on a second run"
fi

if grep -Fq 'Using existing llama-server at http://host.internal:19090/custom/v1' "$EXTERNAL_RERUN_OUTPUT"; then
  pass "setup.sh reports the configured external llama endpoint during rerun reuse"
else
  show_captured_output 'external rerun output' "$EXTERNAL_RERUN_OUTPUT"
  fail "setup.sh should report the configured external llama endpoint during rerun reuse"
fi

if grep -Fq 'LLAMA_BASE_URL="http://host.internal:19090/custom/v1"' "$ENV_FILE"; then
  pass "setup.sh preserves the configured external llama base url across the rerun path"
else
  fail "setup.sh should preserve the configured external llama base url across the rerun path"
fi

if grep -Fq 'LLAMA_EXTERNAL="true"' "$ENV_FILE"; then
  pass "setup.sh preserves the external llama opt-in across the rerun path"
else
  fail "setup.sh should preserve the external llama opt-in across the rerun path"
fi

if grep -Fq 'Detected unhealthy llama-server state at http://127.0.0.1:19090' "$EXTERNAL_RERUN_OUTPUT"; then
  show_captured_output 'external rerun output' "$EXTERNAL_RERUN_OUTPUT"
  fail "setup.sh should not treat the configured external llama endpoint as unhealthy on rerun"
else
  pass "setup.sh does not misclassify the configured external llama endpoint as unhealthy on rerun"
fi

reset_mock_llama_state
prepare_test_env

set_mock_llama_instance "$(id -un 2>/dev/null || echo tester)" 'login -pfl tester /bin/zsh'
pass "setup.sh reuse-path fixture defines a deterministic current-user llama instance"

run_setup_with_input "$EXISTING_OUTPUT" '2\n' || true

if detect_test_llama_install_mode; then
  fail "setup.sh should skip managed llama installation when an existing instance is reused"
else
  pass "setup.sh skips managed llama installation when an existing instance is reused"
fi

reset_mock_llama_state

if run_setup "$RUN1_OUTPUT"; then
  pass "setup.sh runs successfully"
else
  show_captured_output 'run1 output' "$RUN1_OUTPUT"
  fail "setup.sh exited with an error"
fi

log_error() {
  :
}

# shellcheck source=/dev/null
. "$ROOT_DIR/lib/ssh.sh"

if ssh_check 'echo ok' >/dev/null 2>&1; then
  pass "SSH connectivity works after VM readiness is ensured"
else
  fail "SSH connectivity does not work after VM readiness is ensured"
fi

if reset_remote_config; then
  pass "remote config is reset to match the local config"
else
  fail "remote config could not be reset to match the local config"
fi

if run_setup "$RUN2_OUTPUT"; then
  pass "setup.sh is idempotent on a second run"
else
  show_captured_output 'run2 output' "$RUN2_OUTPUT"
  fail "setup.sh failed on a second run"
fi

if [ -f "$LOCAL_CONFIG_PATH" ]; then
  pass "config is generated locally"
else
  fail "config is not generated locally"
fi

reset_mock_llama_state
touch "$OPENCLAW_SERVICE_STATE_FILE"

if run_setup "$STALE_OPENCLAW_OUTPUT"; then
  if grep -Fq 'OpenClaw is installed but not running.' "$STALE_OPENCLAW_OUTPUT" \
    && grep -Fq 'Start with: openclaw gateway' "$STALE_OPENCLAW_OUTPUT" \
    && ! grep -Fq 'OpenClaw is already running on the VM.' "$STALE_OPENCLAW_OUTPUT"; then
    pass "setup treats launchctl-loaded OpenClaw without a live process as installed but not running"
  else
    show_captured_output 'stale openclaw output' "$STALE_OPENCLAW_OUTPUT"
    fail "setup should treat launchctl-loaded OpenClaw without a live process as installed but not running"
  fi
else
  show_captured_output 'stale openclaw output' "$STALE_OPENCLAW_OUTPUT"
  fail "setup should complete when OpenClaw is launchctl-loaded without a live process"
fi

configure_test_llama_paths

LLAMA_INSTALL_MODE='user'
LLAMA_WRAPPER_PATH="$CLAWBOX_LLAMA_USER_WRAPPER_DEST"
LLAMA_ENV_PATH="$CLAWBOX_LLAMA_USER_ENV_DEST"
LLAMA_PLIST_PATH="$CLAWBOX_LLAMA_USER_PLIST_DEST"

if [ -x "$LLAMA_WRAPPER_PATH" ] && [ -f "$LLAMA_ENV_PATH" ] && [ -f "$LLAMA_PLIST_PATH" ]; then
  pass "llama user-mode artifacts are installed in the deterministic harness"
  validate_llama_artifacts_for_mode
else
  fail "llama user-mode artifacts are not installed in the deterministic harness"
fi

if ssh "$VM_HOST" 'zsh -l -c "command -v openclaw >/dev/null 2>&1 && openclaw --version >/dev/null 2>&1"' >/dev/null 2>&1; then
  if ssh "$VM_HOST" 'zsh -l -c '\''ps -axo pid=,comm=,args= | awk '\''\''\''$2 == "openclaw" && $0 ~ /(^|[[:space:]])gateway([[:space:]]|$)/ { found=1 } END { exit(found ? 0 : 1) }'\''\''\'''\''' >/dev/null 2>&1; then
    if grep -Eq 'OpenClaw started as a VM user launchd service\.|OpenClaw is already running on the VM\.' "$RUN2_OUTPUT"; then
      pass "OpenClaw detection works for the running state"
    else
      fail "running-state detection output is inconsistent"
    fi

    if ssh "$VM_HOST" 'launchctl print "gui/$(id -u)/com.clawbox.openclaw" >/dev/null 2>&1' >/dev/null 2>&1; then
      pass "OpenClaw launchd service remains loaded after setup"
    else
      fail "OpenClaw launchd service is not loaded after setup"
    fi

    openclaw_state="$(ssh "$VM_HOST" 'pid="$(zsh -l -c '\''ps -axo pid=,comm=,args= | awk '\''\''\''$2 == "openclaw" && $0 ~ /(^|[[:space:]])gateway([[:space:]]|$)/ { print $1; exit }'\''\''\'''\'')"; if [ -n "$pid" ]; then ps -o stat= -p "$pid" | awk "{print \$1}"; fi' 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$openclaw_state" ] && [[ "$openclaw_state" != *'+'* ]]; then
      pass "OpenClaw process is detached from the SSH controlling terminal"
    else
      fail "OpenClaw process should not remain attached to the SSH controlling terminal"
    fi
  else
    if grep -Eq 'OpenClaw is installed but not running\.|OpenClaw started as a VM user launchd service\.' "$RUN2_OUTPUT"; then
      pass "OpenClaw detection works for the installed but not running state"
    else
      fail "stopped-state detection output is inconsistent"
    fi
  fi
else
  if grep -F 'OpenClaw is not installed on the VM.' "$RUN2_OUTPUT" >/dev/null 2>&1; then
    pass "OpenClaw detection works for the not installed state"
  else
    fail "not-installed detection output is inconsistent"
  fi
fi

if grep -Fq 'Bootstrap failed:' "$RUN2_OUTPUT" && grep -Fq 'OpenClaw started as a VM user launchd service.' "$RUN2_OUTPUT"; then
  fail "setup.sh should not report both OpenClaw bootstrap failure and runtime startup success"
else
  pass "setup.sh avoids contradictory OpenClaw bootstrap and success messaging"
fi

if grep -F 'Continue?' "$RUN2_OUTPUT" >/dev/null 2>&1; then
  fail "overwrite prompt appears when configs match"
else
  pass "overwrite prompt does not appear when configs match"
fi

if grep -Eq 'parse error near `}|parse error near `<<' "$RUN2_OUTPUT" >/dev/null 2>&1; then
  fail "setup output contains remote zsh parse errors"
else
  pass "setup output does not contain remote zsh parse errors"
fi

if [ -f "$REMOTE_HOME/.openclaw/openclaw.json" ]; then
  temp_remote_config="$(mktemp)"
  jq '.agents.defaults.model.primary = "clawbox/__clawbox_test_diff__"' \
    "$REMOTE_HOME/.openclaw/openclaw.json" > "$temp_remote_config"
  mv "$temp_remote_config" "$REMOTE_HOME/.openclaw/openclaw.json"
fi

if run_setup_with_decline "$DIFF_OUTPUT"; then
  pass "setup.sh still completes when overwrite is declined"
else
  show_captured_output 'diff output' "$DIFF_OUTPUT"
  fail "setup.sh failed while testing overwrite prompt on differing config"
fi

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
