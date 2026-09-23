#!/usr/bin/env bash
# =============================================================================
# isp-port-test.sh v2 — ISP inbound port reachability tester
#
# Focus: diagnosing silently-blocked inbound TCP for IRC / mail / identd / web.
# Pairs a listener on the machine behind the ISP with a probe from an external
# host (VPS). TCP is the first-class path; UDP is best-effort + clearly marked
# INCONCLUSIVE (userland can't distinguish open-and-quiet from dropped).
#
# Author: Quaerendir
#
#   TARGET side (behind ISP):  ./isp-port-test.sh listen [profile]
#   PROBE  side (VPS/external): ./isp-port-test.sh probe <target_ip> [profile] [--json]
#   Spot-check single port:     ./isp-port-test.sh quick <target_ip> <port> [--udp]
#
# Profiles: common irc mail web vpn db all
# Port spec format:  PORT:NAME[:tcp|:udp]   (transport defaults to tcp)
# =============================================================================

# NOTE: deliberately NO `set -e`. In a reachability tester a closed port is
# normal control-flow, not an error; -e turns expected non-zero exits into
# silent script death (the v1 REFUSED/BLOCKED branch fell into exactly that
# trap). We keep nounset + pipefail and manage exit codes explicitly.
set -uo pipefail

# --- Colour output (gated on TTY so piped/tee'd output stays clean) ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

PROBE_DEFAULT_TIMEOUT=2
PARALLEL="${PARALLEL:-16}"

# --- Port profiles -----------------------------------------------------------
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
  113:Identd
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

PORT_PROFILES[web]="
  80:HTTP
  443:HTTPS
  8080:HTTP-alt
  8443:HTTPS-alt
"

PORT_PROFILES[vpn]="
  500:IKE:udp
  1194:OpenVPN-UDP:udp
  1723:PPTP:tcp
  4500:IKE-NAT:udp
  51820:WireGuard:udp
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
  ${PORT_PROFILES[web]}
  ${PORT_PROFILES[vpn]}
  ${PORT_PROFILES[db]}
"

# --- Helpers -----------------------------------------------------------------
die() { echo "${RED}error:${NC} $*" >&2; exit 1; }

# Emit normalised "port name transport" lines, deduped by port+transport.
# Pure bash parsing (no fork per line, no grep \s portability trap).
get_ports() {
  local profile="${1:-common}"
  [[ -n "${PORT_PROFILES[$profile]+x}" ]] \
    || die "unknown profile: $profile (have: ${!PORT_PROFILES[*]})"

  local line port name transport
  declare -A seen=()
  while IFS= read -r line; do
    line="${line//[$'\t\r ']/}"          # strip all whitespace
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    port="${line%%:*}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    local rest="${line#*:}"
    name="${rest%%:*}"
    if [[ "$rest" == *:* ]]; then transport="${rest##*:}"; else transport="tcp"; fi
    [[ "$transport" == "udp" ]] || transport="tcp"
    local key="$port/$transport"
    [[ -n "${seen[$key]+x}" ]] && continue
    seen[$key]=1
    printf '%s %s %s\n' "$port" "$name" "$transport"
  done <<< "${PORT_PROFILES[$profile]}"
}

# Pick the best available listener backend once, up front.
detect_listener() {
  if command -v socat >/dev/null 2>&1; then echo socat
  elif command -v python3 >/dev/null 2>&1; then echo python3
  elif command -v nc >/dev/null 2>&1; then echo nc
  else echo none; fi
}

start_listener() {  # backend port transport -> spawns bg listener, prints PID or nothing
  local backend=$1 port=$2 transport=$3 pid=""
  case "$backend" in
    socat)
      if [[ "$transport" == udp ]]; then
        socat UDP-RECVFROM:"$port",fork,reuseaddr /dev/null &>/dev/null &
      else
        socat TCP-LISTEN:"$port",fork,reuseaddr /dev/null &>/dev/null &
      fi
      pid=$! ;;
    python3)
      if [[ "$transport" == udp ]]; then
        python3 - "$port" <<'PY' &>/dev/null &
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(("0.0.0.0",int(sys.argv[1])))
while True: s.recvfrom(1024)
PY
      else
        python3 - "$port" <<'PY' &>/dev/null &
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("0.0.0.0",int(sys.argv[1]))); s.listen(16)
while True:
    c,_=s.accept(); c.close()
PY
      fi
      pid=$! ;;
    nc)
      # OpenBSD nc: `nc -lk PORT` (no -p for listen port). -u for UDP.
      if [[ "$transport" == udp ]]; then nc -u -lk "$port" &>/dev/null &
      else nc -lk "$port" &>/dev/null & fi
      pid=$! ;;
  esac
  # Confirm the child actually survived bind (port busy / <1024 without root).
  sleep 0.05
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; fi
}

# =============================================================================
# LISTEN MODE
# =============================================================================
listen_mode() {
  local profile="${1:-common}"
  [[ -n "${PORT_PROFILES[$profile]+x}" ]] \
    || die "unknown profile: $profile (have: ${!PORT_PROFILES[*]})"
  local backend; backend=$(detect_listener)
  [[ "$backend" == none ]] && die "no listener backend (need socat, python3, or nc)"

  echo "${BOLD}${CYAN}[LISTEN]${NC} profile=${BOLD}$profile${NC} backend=${BOLD}$backend${NC}"
  [[ $EUID -ne 0 ]] && echo "${YELLOW}note:${NC} not root — ports <1024 will fail to bind"
  echo "run probe from your VPS:  ${YELLOW}$0 probe <this_public_ip> $profile${NC}"
  echo "listening (Ctrl+C to stop)..."
  echo

  local pids=() ok=0 fail=0
  while read -r port name transport; do
    local pid; pid=$(start_listener "$backend" "$port" "$transport")
    if [[ -n "$pid" ]]; then
      pids+=("$pid"); ((ok++))
      printf "  ${GREEN}+${NC} %-6s %-16s %s\n" "$port" "$name" "$transport"
    else
      ((fail++))
      printf "  ${RED}x${NC} %-6s %-16s %s  (bind failed — busy or privileged?)\n" \
        "$port" "$name" "$transport"
    fi
  done < <(get_ports "$profile")

  echo
  echo "${BOLD}bound $ok port(s)${NC}${fail:+, ${RED}$fail failed${NC}}"
  [[ $ok -eq 0 ]] && die "nothing is listening; aborting"

  trap 'echo; echo "${YELLOW}stopping...${NC}"; kill "${pids[@]}" 2>/dev/null; exit 0' INT TERM
  wait
}

# =============================================================================
# PROBE ENGINE (single port) — used by probe_mode workers and quick_mode
#   rc: 0=open  1=refused(RST/closed)  2=filtered(timeout/drop)  3=udp-inconclusive
# =============================================================================
probe_one() {
  local target=$1 port=$2 transport=${3:-tcp} to=${4:-$PROBE_DEFAULT_TIMEOUT} ec=0
  if [[ "$transport" == udp ]]; then
    # No reliable userland signal without raw sockets/ICMP parsing. Best-effort
    # datagram, always reported inconclusive.
    command -v nc >/dev/null 2>&1 && timeout "$to" nc -u -z -w"$to" "$target" "$port" &>/dev/null
    return 3
  fi
  # Pass target/port as positional args to the inner bash → no interpolation
  # into the command string (kills the injection foot-gun), single connect.
  timeout "$to" bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$target" "$port" 2>/dev/null || ec=$?
  case $ec in
    0)   return 0 ;;
    124) return 2 ;;   # timeout killed it → packet dropped on the path
    *)   return 1 ;;   # RST → host reachable, port just closed (ISP NOT blocking)
  esac
}

# Fire an ident query at an OPEN 113 and report whether identd actually answers.
# This is the thing that actually causes IRC K-lines, not mere reachability.
ident_query() {
  local target=$1 to=${2:-$PROBE_DEFAULT_TIMEOUT}
  local resp
  resp=$(timeout "$to" bash -c '
    exec 3<>/dev/tcp/"$0"/113 || exit 1
    printf "6667, 6667\r\n" >&3
    head -c 256 <&3' "$target" 2>/dev/null)
  [[ -n "$resp" ]] && echo "${resp//[$'\r\n']/ }"
}

# Worker for xargs: reads one "port name transport" spec, echoes "rc port name transport"
probe_worker() {
  local port=$1 name=$2 transport=$3
  probe_one "$PROBE_TARGET" "$port" "$transport" "$PROBE_TIMEOUT"
  echo "$? $port $name $transport"
}
export -f probe_one probe_worker

# =============================================================================
# PROBE MODE
# =============================================================================
probe_mode() {
  local target="" profile="common" json=0
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      *) if [[ -z "$target" ]]; then target="$a"; else profile="$a"; fi ;;
    esac
  done
  [[ -n "$target" ]] || die "usage: $0 probe <target_ip> [profile] [--json]"
  # Validate here so die aborts the main shell (inside the pipeline below it
  # would only kill the subshell and we'd render a garbage empty table).
  [[ -n "${PORT_PROFILES[$profile]+x}" ]] \
    || die "unknown profile: $profile (have: ${!PORT_PROFILES[*]})"

  export PROBE_TARGET="$target" PROBE_TIMEOUT="$PROBE_DEFAULT_TIMEOUT"

  # Fan out probes in parallel, collect, sort by port. -r/-n3 so an empty
  # profile can't spawn a phantom no-arg worker.
  local results
  results=$(get_ports "$profile" \
    | xargs -r -P "$PARALLEL" -n3 bash -c 'probe_worker "$@"' _ \
    | sort -n -k2)

  local open=() refused=() filtered=() udp=()
  local ident_line=""
  while read -r rc port name transport; do
    [[ -z "${rc:-}" ]] && continue
    case "$rc" in
      0) open+=("$port:$name")
         [[ "$port" == 113 ]] && ident_line=$(ident_query "$target") ;;
      1) refused+=("$port:$name") ;;
      2) filtered+=("$port:$name") ;;
      3) udp+=("$port:$name") ;;
    esac
  done <<< "$results"

  if [[ $json -eq 1 ]]; then
    emit_json "$target" "$profile" open refused filtered udp "$ident_line"
    # exit 0 if nothing dropped, else 1
    [[ ${#filtered[@]} -eq 0 ]]; return
  fi

  echo "${BOLD}${CYAN}[PROBE]${NC} target=${BOLD}$target${NC} profile=${BOLD}$profile${NC} timeout=${PROBE_DEFAULT_TIMEOUT}s"
  echo
  printf "%-7s %-18s %-6s %s\n" "PORT" "SERVICE" "PROTO" "STATUS"
  printf "%-7s %-18s %-6s %s\n" "----" "-------" "-----" "------"
  while read -r rc port name transport; do
    [[ -z "${rc:-}" ]] && continue
    local status
    case "$rc" in
      0) status="${GREEN}OPEN${NC}" ;;
      1) status="${YELLOW}REFUSED${NC}" ;;
      2) status="${RED}BLOCKED/TIMEOUT${NC}" ;;
      3) status="${CYAN}INCONCLUSIVE${NC}" ;;
    esac
    printf "%-7s %-18s %-6s %b\n" "$port" "$name" "$transport" "$status"
  done <<< "$results"

  echo
  echo "${BOLD}=== SUMMARY ===${NC}"
  echo "${GREEN}OPEN         (${#open[@]}):${NC} ${open[*]:-none}"
  echo "${YELLOW}REFUSED      (${#refused[@]}):${NC} ${refused[*]:-none}"
  echo "${RED}BLOCKED      (${#filtered[@]}):${NC} ${filtered[*]:-none}"
  [[ ${#udp[@]} -gt 0 ]] && echo "${CYAN}UDP (n/a)    (${#udp[@]}):${NC} ${udp[*]:-none}"
  [[ -n "$ident_line" ]] && echo "${BOLD}identd@113 answered:${NC} $ident_line"
  echo
  echo "${BOLD}reading:${NC} OPEN+REFUSED = host reachable (ISP not blocking)."
  echo "         BLOCKED = packet dropped on the path — could be ISP, router"
  echo "         port-forward, or host firewall (this test can't tell them apart)."

  # exit non-zero if anything was actually dropped
  [[ ${#filtered[@]} -eq 0 ]]
}

emit_json() {
  local target=$1 profile=$2 ident=$7
  local -n _open=$3 _ref=$4 _filt=$5 _udp=$6
  arr() { local first=1; printf '['; for x in "$@"; do [[ $first -eq 0 ]] && printf ','; printf '"%s"' "$x"; first=0; done; printf ']'; }
  printf '{"target":"%s","profile":"%s","open":' "$target" "$profile"
  arr "${_open[@]}"; printf ',"refused":'; arr "${_ref[@]}"
  printf ',"blocked":'; arr "${_filt[@]}"; printf ',"udp_inconclusive":'; arr "${_udp[@]}"
  printf ',"identd":"%s"}\n' "${ident//\"/\\\"}"
}

# =============================================================================
# QUICK MODE — single port, no listener
# =============================================================================
quick_mode() {
  local target="" port="" transport="tcp"
  for a in "$@"; do
    case "$a" in
      --udp) transport="udp" ;;
      *) if [[ -z "$target" ]]; then target="$a"; else port="$a"; fi ;;
    esac
  done
  [[ -n "$target" && -n "$port" ]] || die "usage: $0 quick <target_ip> <port> [--udp]"

  echo "${BOLD}quick:${NC} $target:$port/$transport"
  probe_one "$target" "$port" "$transport" 3
  case $? in
    0) echo "${GREEN}OPEN${NC}"
       if timeout 3 openssl s_client -connect "$target:$port" </dev/null 2>/dev/null | grep -q "CONNECTED"; then
         echo "  ${CYAN}(TLS handshake ok)${NC}"
       fi
       [[ "$port" == 113 ]] && { local r; r=$(ident_query "$target" 3); [[ -n "$r" ]] && echo "  ${CYAN}identd: $r${NC}"; }
       exit 0 ;;
    1) echo "${YELLOW}REFUSED${NC} (reachable, nothing listening)"; exit 1 ;;
    2) echo "${RED}BLOCKED/TIMEOUT${NC} (dropped on path)"; exit 1 ;;
    3) echo "${CYAN}UDP INCONCLUSIVE${NC} (no userland signal)"; exit 0 ;;
  esac
}

# =============================================================================
# MAIN
# =============================================================================
usage() {
  cat <<EOF
${BOLD}isp-port-test.sh v2${NC} — ISP inbound port reachability tester

${BOLD}USAGE${NC}
  $0 listen [profile]                    # on machine behind ISP
  $0 probe  <target_ip> [profile] [--json]  # from VPS/external host
  $0 quick  <target_ip> <port> [--udp]   # single-port spot-check

${BOLD}PROFILES${NC}  common irc mail web vpn db all
${BOLD}ENV${NC}       PARALLEL=<n>  (probe fan-out, default 16)

${BOLD}NOTES${NC}
  * TCP is authoritative. UDP is best-effort and reported INCONCLUSIVE —
    userland can't distinguish open-and-quiet from dropped.
  * BLOCKED means dropped somewhere on the path: ISP, router port-forward,
    or host firewall. The test cannot attribute which.
  * profile 'irc' includes identd/113 and runs a live ident query on OPEN.
EOF
  exit 1
}

case "${1:-}" in
  listen) shift; listen_mode "${1:-common}" ;;
  probe)  shift; probe_mode "$@" ;;
  quick)  shift; quick_mode "$@" ;;
  *)      usage ;;
esac
