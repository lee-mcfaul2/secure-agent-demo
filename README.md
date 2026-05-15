# secure-agent-demo

Umbrella Helm chart + bring-up scripts for the AI Agent Security Platform demo.

## Quickstart

```bash
make demo            # bring up the full platform on KIND
make smoke           # verify the happy path + blocked-attack
make traffic-burst   # fire 50 prompts at the gateway
make demo-down       # tear down
```

See `docs/walkthrough.md` for the demo script and `docs/troubleshooting.md` for common issues.
