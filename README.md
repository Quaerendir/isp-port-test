# isp-port-test

ISP inbound port reachability tester. Diagnoses which ports your ISP silently blocks by coordinating a listener on your home machine with a probe from an external host (VPS, cloud instance, etc.).

Useful when you hit issues like:
- IRC K-lines due to missing identd (port 113 blocked)
- SSL/TLS connections failing on non-standard ports
- Services unreachable despite correct firewall rules

## Requirements

- `bash` 4+
- `nc` (netcat) — on listener side
- `openssl` — optional, used for SSL spot-checks in quick mode
- An external host (VPS) to run the probe from

## Usage

### Listen mode — run on machine behind ISP

```bash
./isp-port-test.sh listen [profile]
```

Spins up `nc` listeners on all ports in the selected profile. Keep running while you execute the probe from your VPS.

### Probe mode — run from VPS / external host

```bash
./isp-port-test.sh probe <target_ip> [profile]
```

Attempts TCP connect to each port and reports OPEN / REFUSED / BLOCKED with a summary.

### Quick mode — single port spot-check

```bash
./isp-port-test.sh quick <target_ip> <port>
```

No listener needed. Also attempts SSL handshake for SSL ports.

## Port Profiles

| Profile  | Ports covered |
|----------|--------------|
| `common` | FTP, SSH, Telnet, SMTP, DNS, HTTP, Identd, HTTPS, RDP, VNC, HTTP-alt, HTTPS-alt |
| `irc`    | 6667–6669, 6697, 7000, 7070, 8067 |
| `mail`   | SMTP, POP3, IMAP and all SSL variants (465, 587, 993, 995) |
| `vpn`    | OpenVPN, WireGuard, IKE, PPTP |
| `db`     | MySQL, PostgreSQL, MSSQL, Redis, MongoDB |
| `all`    | Everything above |

## Example workflow

```bash
# 1. On home machine — listen on all IRC ports
./isp-port-test.sh listen irc

# 2. From VPS — probe home IP
./isp-port-test.sh probe 1.2.3.4 irc

# 3. Quick SSL check
./isp-port-test.sh quick 1.2.3.4 6697
```

### Example output (probe mode)

```
[PROBE MODE] Target: 1.2.3.4  Profile: irc
Timeout per port: 2s

PORT     SERVICE              STATUS
----     -------              ------
6667     IRC-plain            OPEN
6668     IRC-alt              OPEN
6669     IRC-alt2             OPEN
6697     IRC-SSL              BLOCKED/TIMEOUT
7000     IRC-SSL-alt          BLOCKED/TIMEOUT
7070     IRC-SSL-alt2         BLOCKED/TIMEOUT
8067     IRC-alt3             OPEN

=== SUMMARY ===
OPEN    (4): 6667:IRC-plain 6668:IRC-alt 6669:IRC-alt2 8067:IRC-alt3
REFUSED (0):
BLOCKED (3): 6697:IRC-SSL 7000:IRC-SSL-alt 7070:IRC-SSL-alt2
```

## Adding custom ports

Edit the `PORT_PROFILES` array in the script. Format is `PORT:SERVICE-NAME`, one per line:

```bash
PORT_PROFILES[custom]="
  8888:my-app
  9000:another-service
  12345:custom-port
"
```

Then use with `./isp-port-test.sh listen custom` / `./isp-port-test.sh probe <ip> custom`.

## License

MIT
