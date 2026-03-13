#!/usr/bin/env bash
# =============================================================================
# isp-port-test.sh — ISP inbound port reachability tester
# Usage:
#   TARGET side (machine behind ISP):  ./isp-port-test.sh listen [port_profile]
#   PROBE  side (VPS/external host):   ./isp-port-test.sh probe <target_ip> [port_profile]
#
# Port profiles: common (default) | irc | mail | vpn | db | all
# =============================================================================

set -euo pipefail

# --- Colour output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# --- Port profiles ---
declare -A PORT_PROFILES

PORT_PROFILES[common]="
  21:FTP
  22:SSH
  23:Telnet
  25:SMTP
  53:DNS
  80:HTTP
  113:Identd
  443:HTTPS
  3389:RDP
  5900:VNC
  8080:HTTP-alt
  8443:HTTPS-alt
"

PORT_PROFILES[irc]="
  6667:IRC-plain
  6668:IRC-alt
  6669:IRC-alt2
  6697:IRC-SSL
  7000:IRC-SSL-alt
  7070:IRC-SSL-alt2
  8067:IRC-alt3
"

PORT_PROFILES[mail]="
  25:SMTP
  110:POP3
  143:IMAP
  465:SMTPS
  587:SMTP-submission
  993:IMAPS
  995:POP3S
"

PORT_PROFILES[vpn]="
  500:IKE
  1194:OpenVPN-UDP
  1723:PPTP
  4500:IKE-NAT
  51820:WireGuard
"

PORT_PROFILES[db]="
  1433:MSSQL
  1521:Oracle
  3306:MySQL
  5432:PostgreSQL
  6379:Redis
  27017:MongoDB
"

PORT_PROFILES[all]="
  ${PORT_PROFILES[common]}
  ${PORT_PROFILES[irc]}
  ${PORT_PROFILES[mail]}
  ${PORT_PROFILES[vpn]}
  ${PORT_PROFILES[db]}
"

# --- Helpers ---
get_ports() {
  local profile="${1:-common}"
  if [[ -z "${PORT_PROFILES[$profile]+x}" ]]; then
    echo "Unknown profile: $profile. Available: common irc mail vpn db all" >&2
    exit 1
  fi
  echo "${PORT_PROFILES[$profile]}" | grep -E '^\s*[0-9]+:' | tr -d ' '
}

parse_port() { echo "$1" | cut -d: -f1; }
parse_name() { echo "$1" | cut -d: -f2; }

# =============================================================================
# LISTEN MODE — run on the machine behind ISP
# =============================================================================
listen_mode() {
  local profile="${1:-common}"
  local pids=()
  local ports=()

  echo -e "${BOLD}${CYAN}[LISTEN MODE]${NC} Profile: ${BOLD}$profile${NC}"
  echo -e "Run probe from your VPS/external host:"
  echo -e "  ${YELLOW}$0 probe <this_machine_public_ip> $profile${NC}\n"
  echo -e "Listening on ports (Ctrl+C to stop)...\n"

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local port name
    port=$(parse_port "$entry")
    name=$(parse_name "$entry")
    # nc listen, suppress output, background
    nc -lk -p "$port" &>/dev/null &
    pids+=($!)
    ports+=("$port/$name")
    echo -e "  ${GREEN}+${NC} $port ($name)"
  done <<< "$(get_ports "$profile")"

  echo -e "\n${BOLD}Listening on ${#pids[@]} ports. Waiting for probe...${NC}"
  echo -e "PIDs: ${pids[*]}"

  # Cleanup on exit
  trap 'echo -e "\n${YELLOW}Stopping listeners...${NC}"; kill "${pids[@]}" 2>/dev/null; echo "Done."; exit 0' INT TERM

  wait
}

# =============================================================================
# PROBE MODE — run from VPS / external host
# =============================================================================
probe_mode() {
  local target="${1:?Usage: $0 probe <target_ip> [profile]}"
  local profile="${2:-common}"
  local timeout_sec=2

  local open=() blocked=() filtered=()

  echo -e "${BOLD}${CYAN}[PROBE MODE]${NC} Target: ${BOLD}$target${NC}  Profile: ${BOLD}$profile${NC}"
  echo -e "Timeout per port: ${timeout_sec}s\n"
  printf "%-8s %-20s %s\n" "PORT" "SERVICE" "STATUS"
  printf "%-8s %-20s %s\n" "----" "-------" "------"

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local port name result
    port=$(parse_port "$entry")
    name=$(parse_name "$entry")

    if timeout "$timeout_sec" bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null; then
      result="${GREEN}OPEN${NC}"
      open+=("$port:$name")
    else
      # Distinguish refused (port exists, actively rejected) vs timeout (filtered)
      local exit_code
      timeout "$timeout_sec" bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null
      exit_code=$?
      if [[ $exit_code -eq 1 ]]; then
        result="${YELLOW}REFUSED${NC}"
        filtered+=("$port:$name")
      else
        result="${RED}BLOCKED/TIMEOUT${NC}"
        blocked+=("$port:$name")
      fi
    fi

    printf "%-8s %-20s " "$port" "$name"
    echo -e "$result"

  done <<< "$(get_ports "$profile")"

  # Summary
  echo -e "\n${BOLD}=== SUMMARY ===${NC}"
  echo -e "${GREEN}OPEN    (${#open[@]}):${NC}    ${open[*]:-none}"
  echo -e "${YELLOW}REFUSED (${#filtered[@]}):${NC} ${filtered[*]:-none}"
  echo -e "${RED}BLOCKED (${#blocked[@]}):${NC}  ${blocked[*]:-none}"
  echo ""

  # Exit code: 0 if all open, 1 if any blocked
  [[ ${#blocked[@]} -eq 0 ]]
}

# =============================================================================
# QUICK MODE — single port check, no listener needed
# =============================================================================
quick_mode() {
  local target="${1:?Usage: $0 quick <target_ip> <port>}"
  local port="${2:?Provide port number}"
  local timeout_sec=3

  echo -e "${BOLD}Quick check:${NC} $target:$port"

  if timeout "$timeout_sec" bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null; then
    echo -e "${GREEN}OPEN${NC}"
    exit 0
  else
    echo -e "${RED}CLOSED/BLOCKED${NC}"
    # Try openssl for SSL ports
    if timeout "$timeout_sec" openssl s_client -connect "$target:$port" </dev/null 2>/dev/null | grep -q "CONNECTED"; then
      echo -e "  ${CYAN}(SSL handshake succeeded)${NC}"
    fi
    exit 1
  fi
}

# =============================================================================
# MAIN
# =============================================================================
usage() {
  cat <<EOF
${BOLD}isp-port-test.sh${NC} — ISP inbound port reachability tester

${BOLD}USAGE:${NC}
  $0 listen [profile]              # Run on machine behind ISP
  $0 probe  <target_ip> [profile]  # Run from VPS/external host
  $0 quick  <target_ip> <port>     # Single port spot-check

${BOLD}PROFILES:${NC}
  common  — FTP SSH Telnet SMTP DNS HTTP Identd HTTPS RDP VNC (default)
  irc     — IRC ports 6667-7070
  mail    — SMTP POP3 IMAP and SSL variants
  vpn     — OpenVPN WireGuard IKE PPTP
  db      — MySQL PostgreSQL MSSQL Redis MongoDB
  all     — Everything above

${BOLD}EXAMPLES:${NC}
  # On home machine:
  $0 listen irc

  # On VPS:
  $0 probe 1.2.3.4 irc

  # Quick single port:
  $0 quick 1.2.3.4 6697
EOF
  exit 1
}

case "${1:-}" in
  listen) listen_mode "${2:-common}" ;;
  probe)  probe_mode  "${2:-}" "${3:-common}" ;;
  quick)  quick_mode  "${2:-}" "${3:-}" ;;
  *)      usage ;;
esac
