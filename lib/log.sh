LOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$LOG_LIB_DIR/output.sh"
source "$LOG_LIB_DIR/log-paths.sh"

blank() {
  blank_line
}

note() {
  out "$1"
}

print_divider() {
  divider
}

info_line() {
  step "$1"
}

success_line() {
  success "$1"
}

warn_line() {
  warn "$1"
}

log_error() {
  error "$1"
}

print_blank() {
  blank_line
}
