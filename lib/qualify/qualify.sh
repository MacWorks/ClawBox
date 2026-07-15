#!/usr/bin/env bash

# Shared host-side helpers for publishing and running the VM qualification suite.
# Callers must source output/log/ssh helpers first.

QUALIFY_SUITE_VERSION="1"
QUALIFY_REMOTE_RELATIVE_PATH=".openclaw/workspace/.clawbox/qualification"

qualify_shell_quote() {
  printf '%q' "$1"
}

qualify_source_dir() {
  printf '%s\n' "$BASE_DIR/vm/qualification"
}

qualify_remote_payload_dir() {
  printf '%s\n' "${VM_RUNTIME_PATH:?VM_RUNTIME_PATH is not set}/qualification"
}

qualify_remote_dir() {
  printf '%s\n' "\$HOME/$QUALIFY_REMOTE_RELATIVE_PATH"
}

qualify_remote_runs_dir() {
  printf '%s\n' "\$HOME/$QUALIFY_REMOTE_RELATIVE_PATH/runs"
}

qualify_suite_checksum() {
  local source_dir=''

  source_dir="$(qualify_source_dir)"
  python3 - "$source_dir" <<'PY'
import hashlib, os, sys
root = os.path.abspath(sys.argv[1])
entries = []
for current, dirs, files in os.walk(root):
    dirs[:] = sorted(d for d in dirs if d != "runs")
    for name in sorted(files):
        path = os.path.join(current, name)
        rel = os.path.relpath(path, root)
        mode = oct(os.stat(path).st_mode & 0o777)
        with open(path, "rb") as fh:
            entries.append((rel, mode, hashlib.sha256(fh.read()).hexdigest()))
digest = hashlib.sha256()
for rel, mode, file_digest in entries:
    digest.update(rel.encode("utf-8") + b"\0" + mode.encode("ascii") + b"\0" + file_digest.encode("ascii") + b"\0")
print(digest.hexdigest())
PY
}

qualify_manifest_json() {
  local checksum="$1"

  python3 - "$QUALIFY_SUITE_VERSION" "$checksum" <<'PY'
import json, sys
print(json.dumps({"schemaVersion": "1", "suiteVersion": sys.argv[1], "checksum": sys.argv[2]}, separators=(",", ":")))
PY
}

qualify_publish_suite_to_vm_runtime() {
  local source_dir='' runtime_path='' remote_runtime='' remote_parent=''

  require_vm_host || return 1
  source_dir="$(qualify_source_dir)"
  runtime_path="${VM_RUNTIME_PATH:?VM_RUNTIME_PATH is not set}"
  remote_runtime="$(qualify_shell_quote "$runtime_path")"
  remote_parent="$(qualify_shell_quote "${runtime_path%/*}")"

  [ -d "$source_dir" ] || {
    error "Qualification source suite missing: $source_dir"
    return 1
  }

  tar -C "$BASE_DIR/vm" -cf - qualification \
    | ssh "$VM_HOST" "mkdir -p $remote_parent && rm -rf $remote_runtime/qualification && mkdir -p $remote_runtime && tar -C $remote_runtime -xf -"
}

qualify_remote_manifest_matches() {
  local checksum="$1"
  local remote_dir=''

  remote_dir="$(qualify_remote_dir)"
  ssh_check_zsh "manifest=\"$remote_dir/.clawbox-manifest.json\"
[ -f \"\$manifest\" ] || exit 1
node -e 'const fs=require(\"fs\"); const m=JSON.parse(fs.readFileSync(process.argv[1],\"utf8\")); process.exit(m.suiteVersion===process.argv[2] && m.checksum===process.argv[3] ? 0 : 1)' \"\$manifest\" $(qualify_shell_quote "$QUALIFY_SUITE_VERSION") $(qualify_shell_quote "$checksum")"
}

qualify_install_suite_on_vm() {
  local checksum="$1" manifest='' remote_source='' remote_dir=''

  remote_source="$(qualify_shell_quote "$(qualify_remote_payload_dir)")"
  remote_dir="$(qualify_remote_dir)"
  manifest="$(qualify_manifest_json "$checksum")" || return 1

  ssh_exec_zsh "source_dir=$remote_source
target_dir=\"$remote_dir\"
[ -d \"\$source_dir\" ] || { printf 'Qualification source missing at %s\\n' \"\$source_dir\" >&2; exit 1; }
mkdir -p \"\${target_dir:h}\"
rm -rf \"\$target_dir.tmp\"
mkdir -p \"\$target_dir.tmp\"
cp -R \"\$source_dir\"/. \"\$target_dir.tmp\"/
printf '%s\n' $(qualify_shell_quote "$manifest") > \"\$target_dir.tmp/.clawbox-manifest.json\"
rm -rf \"\$target_dir\"
mv \"\$target_dir.tmp\" \"\$target_dir\"
find \"\$target_dir\" -type d -exec chmod 755 {} \\;
find \"\$target_dir\" -type f -exec chmod 644 {} \\;
chmod 755 \"\$target_dir/runner.sh\"
if [ -d \"\$target_dir/scenarios\" ]; then
  find \"\$target_dir/scenarios\" -type f -name '*.sh' -exec chmod 755 {} \\;
fi"
}

qualify_ensure_suite_installed() {
  local checksum=''

  checksum="$(qualify_suite_checksum)" || return 1
  if qualify_remote_manifest_matches "$checksum" >/dev/null 2>&1; then
    return 0
  fi

  out 'Publishing qualification suite to VM...'
  qualify_publish_suite_to_vm_runtime || return 1
  out 'Installing qualification suite in OpenClaw workspace...'
  qualify_install_suite_on_vm "$checksum"
}

qualify_remote_runner_command() {
  local scenario="$1" json_mode="$2" profile="${3:-full}"
  local remote_dir='' command=''

  remote_dir="$(qualify_remote_dir)"
  command="cd \"$remote_dir\" && ./runner.sh --profile $(qualify_shell_quote "$profile")"
  if [ -n "$scenario" ]; then
    command="$command --scenario $(qualify_shell_quote "$scenario")"
  fi
  if [ "$json_mode" = true ]; then
    command="$command --json"
  fi
  printf '%s\n' "$command"
}
