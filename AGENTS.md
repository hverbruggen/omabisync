# Notes for coding agents

omabisync is an Omarchy shell plugin (Quickshell bar widget). Read the Omarchy plugin docs before changing the manifest or QML.

## Layout

- `manifest.json` declares the plugin, its bar widget and its settings schema.
- `Panel.qml` is the bar icon and popup. It owns the UI only.
- `Service.qml` holds state, runs the helper on a timer, and runs `systemctl --user` for "Sync now" and pause/resume.
- `Model.js` has pure formatting functions. It can be tested with node: `require("./Model.js")`.
- `status.py` produces one JSON snapshot on stdout. It must stay read-only: systemd state, the unit's journal, bisync listing files, and `rclone about` (cached for an hour in `~/.cache/omabisync/`). It must never run a sync.

## Testing

- `omarchy plugin validate .` checks the manifest.
- Run `python3 status.py <unit>` and inspect the JSON.
- Hot reload replaces plugin code but can leave the old widget instance in the bar. Run `omarchy restart shell` to be sure you are looking at the new version.
- `quickshell ipc -p /usr/share/omarchy/shell call hverbruggen.omabisync <open|close|refresh|status|syncNow>` drives the widget without clicking.
- Read shell errors with `quickshell log -p /usr/share/omarchy/shell`.
- Never use real user data in screenshots for the README. Feed the widget a fake status instead.

## Things that went wrong before

- Journal entries from the service process carry `_SYSTEMD_INVOCATION_ID`, while systemd's own "Starting/Finished" lines carry `USER_INVOCATION_ID`. Group runs by either.
- bisync colours some log lines with ANSI codes even under systemd. Strip them before matching.
- Every symlink produces a "Can't follow symlink" line. Filter these in journalctl itself (`-g '^(?!.*follow symlink)'`), since there can be thousands per run.
- Without `--fast-list`, bisync lists a remote one folder at a time. On a pCloud remote with about 45,000 folders a run took 25 to 55 minutes. With `--fast-list` it took two.
- `--skip-links` and other local backend flags change the name rclone gives the local side (`local__...`), so bisync looks for different listing files and stops with "cannot find prior Path1 or Path2 listings". Don't suggest adding them to an existing job.
- `--resync` never deletes. Files deleted on one side while sync was off come back.
- `--dry-run` without `--resync` can fail with the same "cannot find prior listings" error even when the listings exist.
- Stopping a running bisync with SIGTERM shuts down cleanly and `--recover` handles the next run, but the journal records that run as failed.
