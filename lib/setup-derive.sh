parse_vm_user_from_host() {
  local vm_host="$1"

  REPLY=''

  case "$vm_host" in
    *@*)
      REPLY="${vm_host%@*}"
      ;;
  esac
  return 0
}

parse_vm_ip_from_host() {
  local vm_host="$1"

  REPLY=''

  case "$vm_host" in
    *@*)
      REPLY="${vm_host##*@}"
      ;;
  esac

  return 0
}

derive_host_ip_from_vm_ip() {
  local vm_ip="$1"
  local IFS=.
  local o1
  local o2
  local o3
  local o4

  REPLY=""
  vm_ip="$(printf '%s' "$vm_ip" | tr -d '\r\n[:space:]')"

  case "$vm_ip" in
    ''|*[^0-9.]*)
      return 0
      ;;
  esac

  read -r o1 o2 o3 o4 <<< "$vm_ip"

  if [ -z "$o1" ] || [ -z "$o2" ] || [ -z "$o3" ]; then
    return 0
  fi

  REPLY="${o1}.${o2}.${o3}.1"
  return 0
}

derive_shared_subnet_from_vm_ip() {
  local vm_ip="$1"
  local first_octet
  local second_octet
  local third_octet
  local fourth_octet

  REPLY=''

  IFS=. read -r first_octet second_octet third_octet fourth_octet <<EOF
$vm_ip
EOF

  if [ -z "${first_octet:-}" ] || [ -z "${second_octet:-}" ] || [ -z "${third_octet:-}" ]; then
    return 0
  fi

  REPLY="$first_octet.$second_octet.$third_octet.0/24"
  return 0
}

derive_runtime_path() {
  local user_path="$1"

  REPLY=''

  if [ -z "$user_path" ]; then
    return 0
  fi

  REPLY="${user_path%/}/ClawBox"
  return 0
}

derive_llama_bin_path() {
  REPLY=''

  if [ -n "${HOME:-}" ]; then
    REPLY="$HOME/ai/llama.cpp/build/bin/llama-server"
  fi

  return 0
}

derive_models_directory_from_model_path() {
  local model_path="$1"

  REPLY=''

  if [ -z "$model_path" ]; then
    return 0
  fi

  case "$model_path" in
    */*)
      REPLY="${model_path%/*}"
      ;;
  esac

  return 0
}

derive_model_filename() {
  local model_path="$1"

  REPLY=''

  if [ -z "$model_path" ]; then
    return 0
  fi

  REPLY="${model_path##*/}"
  return 0
}

model_path_is_supported_file() {
  local model_path="$1"

  if [ -z "$model_path" ] || [ ! -f "$model_path" ]; then
    return 1
  fi

  case "$model_path" in
    *.gguf)
      return 0
      ;;
  esac

  return 1
}

derive_openclaw_model_id() {
  local model_filename="$1"

  REPLY=''

  if [ -z "$model_filename" ]; then
    return 0
  fi

  model_filename="${model_filename%.gguf}"
  REPLY="$(printf '%s\n' "$model_filename" | tr '[:upper:]' '[:lower:]')"
  return 0
}

list_models_in_directory() {
  local models_dir="$1"

  if [ ! -d "$models_dir" ]; then
    return
  fi

  find "$models_dir" -maxdepth 1 -type f -name '*.gguf' ! -name '.*' -exec basename {} \; | LC_ALL=C sort
}

build_llama_base_url() {
  local host_ip="$1"
  local port="$2"

  if [ -z "$host_ip" ] || [ -z "$port" ]; then
    return
  fi

  printf 'http://%s:%s/v1\n' "$host_ip" "$port"
}

parse_host_ip_from_base_url() {
  local base_url="$1"
  local host_port

  REPLY=""

  case "$base_url" in
    http://*/*)
      host_port="${base_url#http://}"
      host_port="${host_port%%/*}"
      REPLY="${host_port%%:*}"
      return 0
      ;;
    https://*/*)
      host_port="${base_url#https://}"
      host_port="${host_port%%/*}"
      REPLY="${host_port%%:*}"
      return 0
      ;;
  esac

  return 0
}