# Disaster recovery runbook

How to get data back from restic, from a single file up to a full host
rebuild. Written to be followed at 2 a.m. without thinking too hard.

## What is backed up

| Host   | Paths                                   | Notes                                                    |
|--------|-----------------------------------------|----------------------------------------------------------|
| edge01 | `/etc`, `/opt/stacks`, `/opt/traefik`   | Vaultwarden and Uptime Kuma data, `acme.json` certificates |
| mon01  | `/etc`, `/opt/stacks`                   | Stack config only; metrics and logs are not backed up    |

- Schedule: daily at 03:00 (+ up to 30 min random delay), `Persistent=true`.
- Retention: 7 daily, 4 weekly, 6 monthly snapshots.
- Integrity: `restic check --read-data-subset=5%` every Sunday.
- SQLite databases are copied with `sqlite3 .backup` right before each run
  (`db-backup.sqlite3`, `kuma-backup.db`). **Restore those copies**, not the
  live files, which may have been captured mid-write.

**Targets:** RPO 24h (one nightly backup). RTO about 1h for a full host
rebuild, most of it spent on OS install and image pulls.

## What you need before anything else

1. The **Ansible vault password** (stored in the password manager *and* on
   paper; Vaultwarden itself may be the thing that is down).
2. From the vault: `vault_backup_restic_password`,
   `vault_backup_s3_access_key_id`, `vault_backup_s3_secret_access_key`.
3. A machine with `restic` installed (any Linux box or WSL).

> If the restic password is lost, the backups are unrecoverable. There is no
> reset. That is why it is kept in two places outside the lab.

## 0. Set up a restic shell

On a host that was deployed by Ansible, everything is already in place:

```bash
sudo -i
set -a; source /etc/restic/restic.env; set +a
restic snapshots
```

On any other machine:

```bash
export RESTIC_REPOSITORY="s3:https://s3.eu-central-003.backblazeb2.com/homelab-restic/edge01"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export RESTIC_PASSWORD_FILE=~/restic-password   # chmod 600, delete afterwards
restic snapshots --host edge01
```

## 1. Restore a single file or directory

```bash
# Find the snapshot
restic snapshots --path /opt/stacks
# See what it contains
restic ls latest /opt/stacks/uptime-kuma
# Restore next to the original, never over it
restic restore latest --target /tmp/restore --include /opt/stacks/uptime-kuma/data
diff -r /tmp/restore/opt/stacks/uptime-kuma/data /opt/stacks/uptime-kuma/data
```

Browsing interactively also works: `restic mount /mnt/restic` (needs FUSE),
then `ls /mnt/restic/snapshots/latest/`.

## 2. Restore Vaultwarden

```bash
cd /opt/stacks/vaultwarden
docker compose down

restic restore latest --target /tmp/restore --include /opt/stacks/vaultwarden/data
mv data "data.broken.$(date +%F)"
cp -a /tmp/restore/opt/stacks/vaultwarden/data ./data

# Use the consistent copy taken before the backup
mv data/db-backup.sqlite3 data/db.sqlite3
rm -f data/db.sqlite3-wal data/db.sqlite3-shm
sqlite3 data/db.sqlite3 'PRAGMA integrity_check;'   # must print "ok"

docker compose up -d
docker compose logs -f
```

Log in from a browser and check a few entries before deleting
`data.broken.*`. Uptime Kuma is the same procedure with
`/opt/stacks/uptime-kuma/data` and `kuma-backup.db` -> `kuma.db`.

## 3. Rebuild a host from scratch

Use this when the VM is gone (disk failure, broken upgrade, ransomware).

1. **Create the VM** with the same IP address and a user `ops` with your SSH
   key (cloud-init or the installer).
2. **Converge it with Ansible**, skipping the stacks for now so empty data
   directories are not started:

   ```bash
   ansible-playbook site.yml --limit edge01 --skip-tags services
   ```

   The backup role finds the existing repository and does **not** re-init it
   (it only runs `restic init` when the repository is missing).
3. **Restore the data**:

   ```bash
   sudo -i
   set -a; source /etc/restic/restic.env; set +a
   restic snapshots --host edge01          # pick the snapshot ID
   restic restore <id> --target / --include /opt/stacks --include /opt/traefik
   ```

   `/etc` is not restored wholesale: Ansible already rebuilt it. Pull single
   files from the snapshot if something was hand-edited.
4. **Fix SQLite files** as in section 2 (use the `*-backup` copies).
5. **Start the stacks**:

   ```bash
   ansible-playbook site.yml --limit edge01 --tags reverse_proxy,services
   ```

6. **Verify**: Uptime Kuma is all green, Vaultwarden login works, Grafana
   shows the host as `up`, and the next nightly backup succeeds
   (`systemctl list-timers restic-backup.timer`).

Restoring `acme.json` avoids hitting Let's Encrypt rate limits. If it is lost,
Traefik simply requests new certificates.

## 4. Rebuild mon01

Nothing to restore except optional config. Converge it and the monitoring
stack comes back with provisioned datasources and dashboards:

```bash
ansible-playbook site.yml --limit mon01
```

Metric and log history starts from zero.

## 5. The S3 bucket is gone

The backups are gone too, but the lab is not. Create a new bucket and keys,
update the vault, run `ansible-playbook site.yml --tags backup` (the
repository is initialised automatically), then trigger a backup:

```bash
ansible homelab -b -m ansible.builtin.systemd_service -a "name=restic-backup.service state=started"
```

## Restore drill

A backup that has never been restored is a hope, not a backup. Every quarter:

- [ ] Restore Vaultwarden into `/tmp/restore` and run `PRAGMA integrity_check`.
- [ ] Restore one random file from a monthly snapshot.
- [ ] Check `restic check` output in `journalctl -u restic-check.service`.
- [ ] Write the date and the time it took at the bottom of this file.

| Date | What was tested | Duration | Notes |
|------|-----------------|----------|-------|
|      |                 |          |       |
