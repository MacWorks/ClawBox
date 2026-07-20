#!/bin/bash
set -euo pipefail

VM_RUNTIME_PATH="$(cd "$(dirname "$0")" && pwd)"
ZPROFILE_PATH="$HOME/.zprofile"
BREW_BIN="/opt/homebrew/bin/brew"
BREW_SHELLENV_LINE='eval "$(/opt/homebrew/bin/brew shellenv)"'
NODE_PATH_LINE='export PATH="/opt/homebrew/opt/node@22/bin:$PATH"'
VM_AUTOMATION_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
OPENCLAW_DEFAULT_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_DEFAULT_CONFIG_PATH="$OPENCLAW_DEFAULT_CONFIG_DIR/openclaw.json"
SOURCE_CONFIG_PATH="$VM_RUNTIME_PATH/openclaw.json"
QUALIFICATION_SOURCE_PATH="$VM_RUNTIME_PATH/qualification"
QUALIFICATION_TARGET_PATH="$HOME/.openclaw/workspace/.clawbox/qualification"
QUALIFICATION_CURRENT_PATH="$QUALIFICATION_TARGET_PATH/current"
QUALIFICATION_RUNS_PATH="$QUALIFICATION_TARGET_PATH/runs"
QUALIFICATION_SUITE_VERSION="1"

fail() {
	echo "$1"
	exit 1
}

require_command() {
	local name="$1"
	if ! command -v "$name" >/dev/null 2>&1; then
		fail "Required command not found: $name"
	fi
}

activate_runtime_path() {
	export PATH="$VM_AUTOMATION_PATH:$PATH"
	hash -r
}

resolve_command_path() {
	local name="$1"
	shift
	local candidate=''

	candidate="$(command -v "$name" 2>/dev/null || true)"
	if [ -n "$candidate" ] && [ -x "$candidate" ]; then
		REPLY="$candidate"
		return 0
	fi

	for candidate in "$@"; do
		if [ -n "$candidate" ] && [ -x "$candidate" ]; then
			REPLY="$candidate"
			return 0
		fi
	done

	return 1
}

append_line() {
	local path="$1"
	local line="$2"

	if [ -s "$path" ] && [ "$(tail -c 1 "$path" 2>/dev/null || true)" != "" ]; then
		printf '\n' >> "$path"
	fi

	printf '%s\n' "$line" >> "$path"
}

ensure_line_once() {
	local path="$1"
	local line="$2"
	local label="$3"
	local count
	local tmp_file

	count=$(grep -Fxc "$line" "$path" 2>/dev/null || true)

	if [ "$count" -eq 0 ]; then
		append_line "$path" "$line"
		echo "Added $label to $path"
		return
	fi

	if [ "$count" -eq 1 ]; then
		echo "$label already present in $path"
		return
	fi

	tmp_file=$(mktemp)
	grep -Fvx "$line" "$path" > "$tmp_file" || true
	mv "$tmp_file" "$path"
	append_line "$path" "$line"
	echo "Removed duplicate $label entries and kept one in $path"
}

cleanup() {
	:
}

qualification_checksum() {
	node - "$QUALIFICATION_SOURCE_PATH" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const root = path.resolve(process.argv[2]);
function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === 'runs' ? [] : walk(full);
    if (!entry.isFile()) return [];
    return [full];
  });
}
const digest = crypto.createHash('sha256');
for (const file of walk(root).sort()) {
  const rel = path.relative(root, file);
  const mode = (fs.statSync(file).mode & 0o777).toString(8);
  const fileDigest = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  digest.update(rel + '\0' + mode + '\0' + fileDigest + '\0');
}
process.stdout.write(digest.digest('hex'));
NODE
}

install_qualification_suite() {
	local checksum manifest current_manifest

	if [ ! -d "$QUALIFICATION_SOURCE_PATH" ]; then
		echo "Qualification suite not found at $QUALIFICATION_SOURCE_PATH"
		echo "Run ./clawbox setup on the host to publish it before using ./clawbox qualify."
		return 0
	fi

	checksum="$(qualification_checksum)"
	manifest="{\"schemaVersion\":\"1\",\"suiteVersion\":\"$QUALIFICATION_SUITE_VERSION\",\"checksum\":\"$checksum\"}"
	current_manifest="$(cat "$QUALIFICATION_CURRENT_PATH/.clawbox-manifest.json" 2>/dev/null || true)"
	if [ "$current_manifest" = "$manifest" ]; then
		echo "Qualification suite already current at $QUALIFICATION_TARGET_PATH"
		mkdir -p "$QUALIFICATION_RUNS_PATH"
		return 0
	fi

	rm -rf "$QUALIFICATION_CURRENT_PATH.tmp"
	mkdir -p "$QUALIFICATION_CURRENT_PATH.tmp" "$QUALIFICATION_RUNS_PATH"
	cp -R "$QUALIFICATION_SOURCE_PATH"/. "$QUALIFICATION_CURRENT_PATH.tmp"/
	printf '%s\n' "$manifest" > "$QUALIFICATION_CURRENT_PATH.tmp/.clawbox-manifest.json"
	rm -rf "$QUALIFICATION_CURRENT_PATH"
	mkdir -p "$QUALIFICATION_TARGET_PATH"
	mv "$QUALIFICATION_CURRENT_PATH.tmp" "$QUALIFICATION_CURRENT_PATH"
	find "$QUALIFICATION_CURRENT_PATH" -type d -exec chmod 755 {} \;
	find "$QUALIFICATION_CURRENT_PATH" -type f -exec chmod 644 {} \;
	chmod 755 "$QUALIFICATION_CURRENT_PATH/runner.sh"
	if [ -d "$QUALIFICATION_CURRENT_PATH/scenarios" ]; then
		find "$QUALIFICATION_CURRENT_PATH/scenarios" -type f -name '*.sh' -exec chmod 755 {} \;
	fi
	echo "Installed qualification suite at $QUALIFICATION_TARGET_PATH"
}

trap cleanup EXIT

require_command "curl"

if [ ! -f "$ZPROFILE_PATH" ]; then
	touch "$ZPROFILE_PATH"
	echo "Created $ZPROFILE_PATH"
else
	echo "$ZPROFILE_PATH already exists"
fi

echo "Ensuring Homebrew"
if command -v brew >/dev/null 2>&1; then
	echo "Homebrew already installed"
else
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [ ! -x "$BREW_BIN" ]; then
	fail "Homebrew not found at $BREW_BIN"
fi

ensure_line_once "$ZPROFILE_PATH" "$BREW_SHELLENV_LINE" "Homebrew shellenv line"
eval "$($BREW_BIN shellenv)"
activate_runtime_path

if ! command -v brew >/dev/null 2>&1; then
	fail "brew command not available after shellenv"
fi

echo "Homebrew ready: $(command -v brew)"

echo "Ensuring node@22"
if brew list node@22 >/dev/null 2>&1; then
	echo "node@22 already installed"
else
	brew install node@22
fi

echo "Ensuring node@22 is linked"
brew link node@22 --force

ensure_line_once "$ZPROFILE_PATH" "$NODE_PATH_LINE" "Node PATH line"
activate_runtime_path

if ! resolve_command_path node "/opt/homebrew/opt/node@22/bin/node" "/opt/homebrew/bin/node" "/usr/local/bin/node"; then
	fail "node command not available after provisioning"
fi

if ! node_version="$("$REPLY" -v 2>/dev/null)"; then
	fail "node -v failed"
fi

echo "Node ready: $REPLY"
echo "Node version: $node_version"

echo "Ensuring OpenClaw"
if npm list -g openclaw >/dev/null 2>&1; then
	echo "OpenClaw already installed"
else
	echo "Installing OpenClaw via npm"
	npm install -g openclaw@latest
fi

if ! resolve_command_path openclaw "/opt/homebrew/bin/openclaw" "/usr/local/bin/openclaw" "$HOME/.local/bin/openclaw"; then
	fail "openclaw command not available after npm install"
fi

openclaw_path="$REPLY"
openclaw_version="$("$openclaw_path" --version 2>/dev/null || true)"

echo "OpenClaw ready: $openclaw_path"
echo "OpenClaw version: $openclaw_version"
echo ""

install_qualification_suite
echo ""

if [ -f "$SOURCE_CONFIG_PATH" ]; then
	mkdir -p "$OPENCLAW_DEFAULT_CONFIG_DIR"

	if [ ! -f "$OPENCLAW_DEFAULT_CONFIG_PATH" ]; then
		cp "$SOURCE_CONFIG_PATH" "$OPENCLAW_DEFAULT_CONFIG_PATH"
		echo "Copied OpenClaw config to $OPENCLAW_DEFAULT_CONFIG_PATH"
	elif cmp -s "$SOURCE_CONFIG_PATH" "$OPENCLAW_DEFAULT_CONFIG_PATH"; then
		echo "OpenClaw config already matches $OPENCLAW_DEFAULT_CONFIG_PATH"
	else
		REPLACE_CONFIG=""
		read -r -p "OpenClaw config already exists at ~/.openclaw/openclaw.json. Replace it? [y/N]: " REPLACE_CONFIG || REPLACE_CONFIG=""

		if [[ "$REPLACE_CONFIG" =~ ^[Yy]$ ]]; then
			cp "$SOURCE_CONFIG_PATH" "$OPENCLAW_DEFAULT_CONFIG_PATH"
			echo "Replaced OpenClaw config at $OPENCLAW_DEFAULT_CONFIG_PATH"
		else
			echo "Keeping existing OpenClaw config at $OPENCLAW_DEFAULT_CONFIG_PATH"
		fi
	fi
else
	echo "OpenClaw config not found at $SOURCE_CONFIG_PATH"
	echo "Run ./clawbox setup on the host to copy it before starting the gateway."
fi

echo ""
echo "VM provisioning complete."
echo "Return to the ClawBox setup process on the host to finish configuration and start OpenClaw."
echo ""
