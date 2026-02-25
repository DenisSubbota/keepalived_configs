# TODO

## Reliability / safety

- [ ] Validate split-brain behavior (network partition between VRRP peers).
- [ ] Consider adding `nopreempt` / priority strategy and documenting expected failback behavior.
- [ ] Add a clear “what happens when no healthy primary exists” section for Writer VIP.
- [ ] Add “shun Reader VIP” sentinel file: if present on a node that currently holds **Reader VIP** (and does **not** hold Writer VIP), it should relinquish Reader VIP so it moves to the primary.
  - [ ] Define default path (example: `/etc/keepalived/shun_reader_vip`) and allow overriding via env/config.
  - [ ] Decide whether this should be implemented as an additional `vrrp_script` in `track_script` or integrated into `check_mysql_reader.sh`.
- [ ] Add alerting/notifiers for unhealthy Writer/Reader VIP state.

## Align behavior with `ip_controller` (optional)

- [ ] Decide whether Writer eligibility should be “RW only” (no replica-attached requirement) to match `ip_controller`.
- [ ] If aligning: update Keepalived weights/track_script configuration accordingly.

## Security / ops

- [ ] Remove hardcoded secrets from configs (`auth_pass`) and scripts (default MySQL creds); document secret injection options.
- [ ] Switch MySQL auth to use a local client config (`.my.cnf`) instead of passing `--user/--password`.
  - [ ] Default path: `/home/percona/.my.cnf` (allow override via env, e.g. `MYSQL_DEFAULTS_FILE`).
  - [ ] Do **not** use `--defaults-extra-file`. Rely on `mysql` option-file auto-discovery (run scripts as `percona` so `/home/percona/.my.cnf` is picked up).
  - [ ] Update scripts to pass only connection parameters (host/port or socket) and use the option file for credentials (avoid embedding secrets in args/env).
- [ ] Add systemd unit / installation steps for scripts under `/etc/keepalived/`.
- [ ] Add log collection / troubleshooting guide (what to look for in Keepalived logs).

## Coverage

- [ ] Test on MySQL 5.7 and 8.0 (scripts claim compatibility).
- [ ] Add multi-replica / multi-reader testing notes.