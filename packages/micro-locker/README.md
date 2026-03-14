# micro-locker

`micro-locker` listens to systemd/logind D-Bus signals and executes commands on lock/unlock/suspend/resume.

Configure behavior with environment variables before starting it:

```bash
ON_LOCK="i3lock" \
ON_UNLOCK="killall i3lock" \
ON_SUSPEND="i3lock" \
ON_RESUME="echo resumed" \
  micro-locker
```

Supported env vars:
- `ON_LOCK`
- `ON_UNLOCK`
- `ON_SUSPEND`
- `ON_RESUME`
