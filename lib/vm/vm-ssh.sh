vm_onboarding_probe_timeout() {
  printf '%s\n' "${CLAWBOX_SSH_ONBOARDING_CONNECT_TIMEOUT:-2}"
}

vm_onboarding_network_probe_timeout() {
  printf '%s\n' "${CLAWBOX_VM_NETWORK_CONNECT_TIMEOUT:-1}"
}

vm_onboarding_bootstrap_timeout() {
  printf '%s\n' "${CLAWBOX_SSH_BOOTSTRAP_CONNECT_TIMEOUT:-3}"
}

vm_onboarding_auth_probe_timeout() {
  printf '%s\n' "${CLAWBOX_SSH_AUTH_PROBE_CONNECT_TIMEOUT:-2}"
}

VM_UNREACHABLE_IPS=''

reset_vm_onboarding_probe_state() {
  VM_UNREACHABLE_IPS=''
}

ssh_target_ipv4() {
  local target_host="$1"
  local host_value="$target_host"

  REPLY=''

  case "$host_value" in
    *@*)
      host_value="${host_value##*@}"
      ;;
  esac

  if vm_ip_is_ipv4 "$host_value"; then
    REPLY="$host_value"
    return 0
  fi

  return 1
}

ssh_target_host() {
  local target_host="$1"

  REPLY="$target_host"

  case "$target_host" in
    *@*)
      REPLY="${target_host##*@}"
      ;;
  esac

  return 0
}

record_unreachable_vm_ip() {
  local ip_value="$1"

  [ -n "$ip_value" ] || return 1

  if vm_ip_in_list "$ip_value" "${VM_UNREACHABLE_IPS:-}"; then
    return 0
  fi

  if [ -n "${VM_UNREACHABLE_IPS:-}" ]; then
    VM_UNREACHABLE_IPS="$VM_UNREACHABLE_IPS
$ip_value"
  else
    VM_UNREACHABLE_IPS="$ip_value"
  fi

  return 0
}

vm_ip_should_be_excluded() {
  local ip_value="$1"

  [ -n "$ip_value" ] || return 0

  if vm_ip_in_list "$ip_value" "${VM_UNREACHABLE_IPS:-}"; then
    return 0
  fi

  if [ -n "${HOST_IP:-}" ] && [ "$ip_value" = "$HOST_IP" ]; then
    return 0
  fi

  return 1
}

probe_ssh_target_endpoint() {
  local target_host="$1"
  local probe_output=''
  local probe_status=0
  local timeout_seconds=''
  local target_ip=''

  timeout_seconds="$(vm_onboarding_probe_timeout)"
  VM_SSH_PROBE_OUTPUT=''
  VM_SSH_PROBE_STATUS=0

  set +e
  probe_output="$(ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="$timeout_seconds" \
    -o ConnectionAttempts=1 \
    -o NumberOfPasswordPrompts=0 \
    -o PreferredAuthentications=none \
    -o PubkeyAuthentication=no \
    -o PasswordAuthentication=no \
    "$target_host" exit 2>&1)"
  probe_status=$?
  set -e

  VM_SSH_PROBE_OUTPUT="$probe_output"
  VM_SSH_PROBE_STATUS=$probe_status

  if ssh_target_ipv4 "$target_host"; then
    target_ip="$REPLY"
  fi

  if [ "$probe_status" -eq 0 ]; then
    REPLY='ready'
    return 0
  fi

  case "$probe_output" in
    *'Could not resolve hostname'*|*'Name or service not known'*|*'nodename nor servname provided'*|*'No address associated with hostname'*)
      REPLY='invalid-target'
      ;;
    *'No route to host'*|*'Host is down'*|*'Network is unreachable'*)
      REPLY='unreachable'
      record_unreachable_vm_ip "$target_ip" >/dev/null 2>&1 || true
      ;;
    *'Connection refused'*)
      REPLY='ssh-refused'
      ;;
    *'Operation timed out'*|*'Connection timed out'*)
      REPLY='ssh-timeout'
      ;;
    *'Permission denied'*|*'Host key verification failed'*|*'REMOTE HOST IDENTIFICATION HAS CHANGED'*)
      REPLY='ssh-auth-required'
      ;;
    *)
      REPLY='unknown'
      ;;
  esac

  return 0
}

probe_vm_ssh_endpoint() {
  probe_ssh_target_endpoint "$VM_HOST"
}

classify_ssh_hostkey_failure() {
  local target_host="$1"
  local probe_output="$2"
  local known_hosts_path="${HOME:-}/.ssh/known_hosts"
  local target_name=''

  case "$probe_output" in
    *'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Offending '*known_hosts*)
      REPLY='ssh-hostkey-changed'
      return 0
      ;;
    *'you have requested strict checking'*|*'strict host key checking'*)
      REPLY='ssh-hostkey-strict'
      return 0
      ;;
  esac

  ssh_target_host "$target_host"
  target_name="$REPLY"

  if [ -z "$target_name" ] || [ ! -f "$known_hosts_path" ]; then
    REPLY='ssh-hostkey-unknown'
    return 0
  fi

  if command -v ssh-keygen >/dev/null 2>&1 \
    && ! ssh-keygen -F "$target_name" -f "$known_hosts_path" >/dev/null 2>&1; then
    REPLY='ssh-hostkey-unknown'
    return 0
  fi

  REPLY='ssh-hostkey-strict'
  return 0
}

accept_new_vm_ssh_host_key() {
  local probe_status=0
  local timeout_seconds=''

  timeout_seconds="$(vm_onboarding_auth_probe_timeout)"

  if [ -n "${HOME:-}" ]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
  fi

  set +e
  ssh -n \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    -o ConnectTimeout="$timeout_seconds" \
    -o ConnectionAttempts=1 \
    -o NumberOfPasswordPrompts=0 \
    "$VM_HOST" 'echo ok' >/dev/null 2>&1
  probe_status=$?
  set -e

  return "$probe_status"
}

probe_ssh_batch_auth_target() {
  local target_host="$1"
  local probe_output=''
  local probe_status=0
  local timeout_seconds=''
  local target_ip=''

  timeout_seconds="$(vm_onboarding_auth_probe_timeout)"
  VM_SSH_AUTH_PROBE_OUTPUT=''
  VM_SSH_AUTH_PROBE_STATUS=0

  set +e
  probe_output="$(ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="$timeout_seconds" \
    -o ConnectionAttempts=1 \
    -o NumberOfPasswordPrompts=0 \
    "$target_host" 'echo ok' 2>&1)"
  probe_status=$?
  set -e

  VM_SSH_AUTH_PROBE_OUTPUT="$probe_output"
  VM_SSH_AUTH_PROBE_STATUS=$probe_status

  if ssh_target_ipv4 "$target_host"; then
    target_ip="$REPLY"
  fi

  if [ "$probe_status" -eq 0 ]; then
    REPLY='ready'
    return 0
  fi

  case "$probe_output" in
    *'Could not resolve hostname'*|*'Name or service not known'*|*'nodename nor servname provided'*|*'No address associated with hostname'*)
      REPLY='invalid-target'
      ;;
    *'No route to host'*|*'Host is down'*|*'Network is unreachable'*)
      REPLY='unreachable'
      record_unreachable_vm_ip "$target_ip" >/dev/null 2>&1 || true
      ;;
    *'Connection refused'*)
      REPLY='ssh-refused'
      ;;
    *'Operation timed out'*|*'Connection timed out'*)
      REPLY='ssh-timeout'
      ;;
    *'Host key verification failed'*|*'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'Offending '*known_hosts*)
      classify_ssh_hostkey_failure "$target_host" "$probe_output"
      ;;
    *'Permission denied'*)
      REPLY='ssh-auth-required'
      ;;
    *)
      REPLY='ssh-remote-command-failed'
      ;;
  esac

  return 0
}

classify_vm_ssh_connectivity() {
  local probe_state=''
  local auth_probe_state=''

  probe_vm_ssh_endpoint
  probe_state="$REPLY"

  if [ "$probe_state" = 'ssh-auth-required' ]; then
    probe_ssh_batch_auth_target "$VM_HOST"
    auth_probe_state="$REPLY"

    case "$auth_probe_state" in
      ready)
        REPLY='ready'
        return 0
        ;;
      ssh-auth-required|ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict|ssh-remote-command-failed|ssh-timeout|ssh-refused|invalid-target|unreachable)
        REPLY="$auth_probe_state"
        return 0
        ;;
    esac
  fi

  case "$probe_state" in
    ready|ssh-auth-required|ssh-refused|ssh-timeout|invalid-target|unreachable|unknown|ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict|ssh-remote-command-failed)
      REPLY="$probe_state"
      ;;
    *)
      REPLY='unknown'
      ;;
  esac

  return 0
}

probe_tcp_target_endpoint() {
  local target_host="$1"
  local target_name=''
  local probe_output=''
  local probe_status=0
  local timeout_seconds=''
  local target_ip=''

  timeout_seconds="$(vm_onboarding_network_probe_timeout)"
  VM_NETWORK_PROBE_OUTPUT=''
  VM_NETWORK_PROBE_STATUS=0

  ssh_target_host "$target_host"
  target_name="$REPLY"

  set +e
  probe_output="$(command perl -MIO::Socket::INET -MTime::HiRes=alarm -e '
    use strict;
    use warnings;

    my ($host, $timeout) = @ARGV;

    local $SIG{ALRM} = sub {
      die "timed out\n";
    };

    alarm($timeout);
    my $socket = IO::Socket::INET->new(
      PeerAddr => $host,
      PeerPort => 22,
      Proto => "tcp",
    ) or die "$!\n";
    close $socket;
    alarm(0);
  ' "$target_name" "$timeout_seconds" 2>&1)"
  probe_status=$?
  set -e

  VM_NETWORK_PROBE_OUTPUT="$probe_output"
  VM_NETWORK_PROBE_STATUS=$probe_status

  if ssh_target_ipv4 "$target_host"; then
    target_ip="$REPLY"
  fi

  if [ "$probe_status" -eq 0 ]; then
    REPLY='ready'
    return 0
  fi

  case "$probe_output" in
    *'Could not resolve hostname'*|*'Name or service not known'*|*'nodename nor servname provided'*|*'No address associated with hostname'*|*'Temporary failure in name resolution'*)
      REPLY='invalid-target'
      ;;
    *'No route to host'*|*'Host is down'*|*'Network is unreachable'*)
      REPLY='unreachable'
      record_unreachable_vm_ip "$target_ip" >/dev/null 2>&1 || true
      ;;
    *'Connection refused'*)
      REPLY='ssh-refused'
      ;;
    *'Operation timed out'*|*'Connection timed out'*|*'timed out'*)
      REPLY='ssh-timeout'
      ;;
    *)
      REPLY='unknown'
      ;;
  esac

  return 0
}

probe_vm_network_endpoint() {
  probe_tcp_target_endpoint "$VM_HOST"
}

vm_ip_is_ipv4() {
  case "$1" in
    *.*.*.*)
      return 0
      ;;
  esac

  return 1
}

utmctl_vm_ip_candidates() {
  local utmctl_bin=''
  local raw_ip_list=''
  local candidate_ip=''
  local discovered_ips=''

  REPLY=''

  [ -n "${VM_MACHINE_NAME:-}" ] || return 1

  if ! command -v resolve_utmctl_bin >/dev/null 2>&1; then
    return 1
  fi

  resolve_utmctl_bin || return 1
  utmctl_bin="$REPLY"

  raw_ip_list="$($utmctl_bin ip-address "$VM_MACHINE_NAME" 2>/dev/null || true)"
  [ -n "$raw_ip_list" ] || return 1

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    if ! vm_ip_is_ipv4 "$candidate_ip"; then
      continue
    fi
    if [ "$candidate_ip" = "${VM_IP:-}" ]; then
      continue
    fi
    if vm_ip_should_be_excluded "$candidate_ip"; then
      continue
    fi

    if [ -n "$discovered_ips" ]; then
      discovered_ips="$discovered_ips
$candidate_ip"
    else
      discovered_ips="$candidate_ip"
    fi
  done <<EOF
$raw_ip_list
EOF

  REPLY="$discovered_ips"
  [ -n "$REPLY" ]
}

derive_vm_shared_subnet() {
  REPLY=''

  if [ -n "${FIREWALL_SHARED_SUBNET:-}" ]; then
    REPLY="$FIREWALL_SHARED_SUBNET"
    return 0
  fi

  if command -v derive_shared_subnet_from_vm_ip >/dev/null 2>&1; then
    derive_shared_subnet_from_vm_ip "${VM_IP:-}"
    return 0
  fi

  return 0
}

vm_shared_subnet_prefix() {
  local subnet_value="$1"
  local network_address=''
  local prefix_octet_1=''
  local prefix_octet_2=''
  local prefix_octet_3=''
  local prefix_octet_4=''

  REPLY=''
  network_address="${subnet_value%%/*}"

  IFS=. read -r prefix_octet_1 prefix_octet_2 prefix_octet_3 prefix_octet_4 <<EOF
$network_address
EOF

  if [ -z "$prefix_octet_1" ] || [ -z "$prefix_octet_2" ] || [ -z "$prefix_octet_3" ]; then
    return 0
  fi

  REPLY="$prefix_octet_1.$prefix_octet_2.$prefix_octet_3"
  return 0
}

vm_neighbor_ips_on_subnet() {
  local subnet_value="$1"
  local subnet_prefix=''

  REPLY=''

  if ! command -v arp >/dev/null 2>&1; then
    return 1
  fi

  vm_shared_subnet_prefix "$subnet_value"
  subnet_prefix="$REPLY"
  [ -n "$subnet_prefix" ] || return 1

  REPLY="$(arp -an 2>/dev/null | awk -v prefix="$subnet_prefix." '
    {
      if (match($0, /\(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\)/)) {
        ip = substr($0, RSTART + 1, RLENGTH - 2)
        if (index(ip, prefix) == 1) {
          print ip
        }
      }
    }
  ' | awk '!seen[$0]++')"

  [ -n "$REPLY" ]
}

capture_vm_ip_discovery_baseline() {
  local subnet_value=''

  VM_IP_DISCOVERY_BASELINE=''
  derive_vm_shared_subnet
  subnet_value="$REPLY"
  [ -n "$subnet_value" ] || return 0

  vm_neighbor_ips_on_subnet "$subnet_value" >/dev/null 2>&1 || return 0
  VM_IP_DISCOVERY_BASELINE="$REPLY"
  return 0
}

vm_ip_in_list() {
  local ip_value="$1"
  local ip_list="$2"
  local existing_ip=''

  while IFS= read -r existing_ip; do
    [ -n "$existing_ip" ] || continue
    if [ "$existing_ip" = "$ip_value" ]; then
      return 0
    fi
  done <<EOF
$ip_list
EOF

  return 1
}

vm_append_candidate_ip() {
  local ip_value="$1"

  [ -n "$ip_value" ] || return 1

  if [ -n "${VM_IP_DISCOVERY_CANDIDATES:-}" ]; then
    if vm_ip_in_list "$ip_value" "$VM_IP_DISCOVERY_CANDIDATES"; then
      return 0
    fi
    VM_IP_DISCOVERY_CANDIDATES="$VM_IP_DISCOVERY_CANDIDATES
$ip_value"
  else
    VM_IP_DISCOVERY_CANDIDATES="$ip_value"
  fi

  return 0
}

vm_generate_likely_subnet_ips() {
  local subnet_value="$1"
  local subnet_prefix=''
  local host_octet=2

  REPLY=''
  vm_shared_subnet_prefix "$subnet_value"
  subnet_prefix="$REPLY"
  [ -n "$subnet_prefix" ] || return 1

  while [ "$host_octet" -le 10 ]; do
    if [ -n "$REPLY" ]; then
      REPLY="$REPLY
$subnet_prefix.$host_octet"
    else
      REPLY="$subnet_prefix.$host_octet"
    fi
    host_octet=$((host_octet + 1))
  done

  return 0
}

discover_vm_ip_candidates() {
  local subnet_value=''
  local current_neighbors=''
  local likely_ips=''
  local utmctl_ips=''
  local candidate_ip=''
  local candidate_target=''
  local candidate_state=''
  local discovered_count=0
  local vm_user="${VM_USER:-}"

  REPLY=''
  VM_IP_DISCOVERY_CANDIDATES=''

  [ -n "$vm_user" ] || return 1

  derive_vm_shared_subnet
  subnet_value="$REPLY"

  if utmctl_vm_ip_candidates; then
    utmctl_ips="$REPLY"

    while IFS= read -r candidate_ip; do
      [ -n "$candidate_ip" ] || continue
      if vm_ip_should_be_excluded "$candidate_ip"; then
        continue
      fi

      candidate_target="${vm_user}@${candidate_ip}"
      probe_ssh_target_endpoint "$candidate_target"
      candidate_state="$REPLY"

      case "$candidate_state" in
        invalid-target)
          continue
          ;;
      esac

      vm_append_candidate_ip "$candidate_ip"
      status_tick 'Attempting VM IP discovery...'
    done <<EOF
$utmctl_ips
EOF
  fi

  if [ -n "$VM_IP_DISCOVERY_CANDIDATES" ]; then
    REPLY="$VM_IP_DISCOVERY_CANDIDATES"
    return 0
  fi

  [ -n "$subnet_value" ] || return 1

  vm_neighbor_ips_on_subnet "$subnet_value" >/dev/null 2>&1 || true
  current_neighbors="$REPLY"

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    if [ "$candidate_ip" = "${VM_IP:-}" ]; then
      continue
    fi
    if vm_ip_should_be_excluded "$candidate_ip"; then
      continue
    fi
    if vm_ip_in_list "$candidate_ip" "${VM_IP_DISCOVERY_BASELINE:-}"; then
      continue
    fi

    candidate_target="${vm_user}@${candidate_ip}"
    probe_ssh_target_endpoint "$candidate_target"
    candidate_state="$REPLY"

    case "$candidate_state" in
      invalid-target|unreachable)
        continue
        ;;
    esac

    vm_append_candidate_ip "$candidate_ip"
    status_tick 'Attempting VM IP discovery...'
  done <<EOF
$current_neighbors
EOF

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    if [ "$candidate_ip" = "${VM_IP:-}" ]; then
      continue
    fi
    if vm_ip_should_be_excluded "$candidate_ip"; then
      continue
    fi
    if vm_ip_in_list "$candidate_ip" "${VM_IP_DISCOVERY_CANDIDATES:-}"; then
      continue
    fi

    candidate_target="${vm_user}@${candidate_ip}"
    probe_ssh_target_endpoint "$candidate_target"
    candidate_state="$REPLY"

    case "$candidate_state" in
      invalid-target|unreachable)
        continue
        ;;
    esac

    vm_append_candidate_ip "$candidate_ip"
    discovered_count=$((discovered_count + 1))
    status_tick 'Attempting VM IP discovery...'
    if [ "$discovered_count" -ge 5 ]; then
      break
    fi
  done <<EOF
$current_neighbors
EOF

  if [ -z "$VM_IP_DISCOVERY_CANDIDATES" ]; then
    vm_generate_likely_subnet_ips "$subnet_value" >/dev/null 2>&1 || true
    likely_ips="$REPLY"

    while IFS= read -r candidate_ip; do
      [ -n "$candidate_ip" ] || continue
      if [ "$candidate_ip" = "${VM_IP:-}" ]; then
        continue
      fi
      if vm_ip_should_be_excluded "$candidate_ip"; then
        continue
      fi

      candidate_target="${vm_user}@${candidate_ip}"
      probe_ssh_target_endpoint "$candidate_target"
      candidate_state="$REPLY"

      case "$candidate_state" in
        invalid-target|unreachable)
          continue
          ;;
      esac

      vm_append_candidate_ip "$candidate_ip"
      discovered_count=$((discovered_count + 1))
      status_tick 'Attempting VM IP discovery...'
      if [ "$discovered_count" -ge 5 ]; then
        break
      fi
    done <<EOF
$likely_ips
EOF
  fi

  REPLY="$VM_IP_DISCOVERY_CANDIDATES"
  [ -n "$REPLY" ]
}

ssh_onboarding_check() {
  local timeout_seconds=''

  timeout_seconds="$(vm_onboarding_probe_timeout)"
  ssh -n -o BatchMode=yes -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 "$VM_HOST" "$@"
}

wait_for_vm_ssh() {
  local attempt=1
  local max_attempts=10

  while [ "$attempt" -le "$max_attempts" ]; do
    if ssh_onboarding_check "exit" >/dev/null 2>&1; then
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

print_manual_ssh_setup_instructions() {
  section 'Manual SSH Setup'
  out 'ssh-keygen -t ed25519'
  out "ssh-copy-id $VM_HOST"
  out "ssh $VM_HOST 'echo ok'"
  out 'If ssh-copy-id is unavailable, use:'
  out "ssh $VM_HOST 'mkdir -p ~/.ssh'"
  out "ssh $VM_HOST 'chmod 700 ~/.ssh'"
  out "scp ~/.ssh/id_ed25519.pub $VM_HOST:~/.ssh/clawbox_id_ed25519.pub"
  out "ssh $VM_HOST 'touch ~/.ssh/authorized_keys'"
  out "ssh $VM_HOST 'chmod 600 ~/.ssh/authorized_keys'"
  out "ssh $VM_HOST 'cat ~/.ssh/clawbox_id_ed25519.pub >> ~/.ssh/authorized_keys'"
  out "ssh $VM_HOST 'rm -f ~/.ssh/clawbox_id_ed25519.pub'"
  out "ssh $VM_HOST 'echo ok'"
}

ensure_host_ssh_key() {
  local key_path="$HOME/.ssh/id_ed25519"

  if [ -f "$key_path" ] && [ -f "$key_path.pub" ]; then
    return 0
  fi

  out 'No SSH key found. Generating ~/.ssh/id_ed25519 now.'
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$key_path" -N ''
}

copy_ssh_key_to_vm() {
  local key_path="$HOME/.ssh/id_ed25519.pub"
  local remote_key_path='~/.ssh/clawbox_id_ed25519.pub'
  local timeout_seconds=''
  local copy_output=''
  local copy_status=0

  timeout_seconds="$(vm_onboarding_bootstrap_timeout)"
  VM_SSH_COPY_ID_OUTPUT=''
  VM_SSH_COPY_ID_STATUS=0

  if command -v ssh-copy-id >/dev/null 2>&1; then
    out 'Copying SSH key to VM with ssh-copy-id...'
    set +e
    copy_output="$(ssh-copy-id -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 -o ServerAliveInterval=1 -o ServerAliveCountMax=1 "$VM_HOST" 2>&1)"
    copy_status=$?
    set -e

    VM_SSH_COPY_ID_OUTPUT="$copy_output"
    VM_SSH_COPY_ID_STATUS=$copy_status

    if [ "$copy_status" -eq 0 ]; then
      return 0
    fi

    case "$copy_output" in
      *'All keys were skipped because they already exist on the remote system.'*|*'Number of key(s) added: 0'*)
        if ssh_onboarding_check 'echo ok' >/dev/null 2>&1; then
          out 'ssh-copy-id reported keys already installed; SSH key auth is already working.'
          return 0
        fi
        ;;
    esac

    return 1
  fi

  out 'ssh-copy-id not found. Using fallback key copy method...'
  scp -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 -q "$key_path" "$VM_HOST:$remote_key_path" </dev/null || return 1
  ssh -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 "$VM_HOST" 'mkdir -p ~/.ssh' </dev/null || return 1
  ssh -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 "$VM_HOST" 'chmod 700 ~/.ssh' </dev/null || return 1
  ssh -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 "$VM_HOST" 'touch ~/.ssh/authorized_keys' </dev/null || return 1
  ssh -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 "$VM_HOST" 'chmod 600 ~/.ssh/authorized_keys' </dev/null || return 1
  ssh -o ConnectTimeout="$timeout_seconds" -o ConnectionAttempts=1 "$VM_HOST" "awk 'NF && !seen[\$0]++' ~/.ssh/authorized_keys $remote_key_path > ~/.ssh/authorized_keys.clawbox && mv ~/.ssh/authorized_keys.clawbox ~/.ssh/authorized_keys && rm -f $remote_key_path" </dev/null || return 1
  return 0
}
