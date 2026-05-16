> # ☢️☢️☢️  DO NOT COPY THIS PATTERN  ☢️☢️☢️
>
> # 🚨🚨🚨  A TOKENIZER MASTER KEY IS COMMITTED TO THIS REPO ON PURPOSE  🚨🚨🚨

---

## What this is

`k_master.txt` is a **throwaway AES master key** for `pii-tokenizer`,
generated once (`openssl rand -base64 32`) and **committed to version control
in plaintext**. The same value is inlined into `chart/values-demo.yaml` (that
inline copy is what Helm actually consumes; this file is for discoverability
and regeneration).

This exists for **exactly one reason**: to make `helm install` genuinely
turnkey — no secret setup. No `cp values-secrets.example.yaml`, no
`openssl rand`, no manual edit.

## Why this is NOT how you do it

`k_master` is the root key under which `pii-tokenizer` AEAD-encrypts every PII
token. Anyone who can read this repo can:

- decrypt every token the tokenizer ever produced,
- forge tokens that the platform will accept as genuine.

In a real system this key is generated in and never leaves a KMS/HSM, accessed
at runtime through `go-kms-wrapping`, rotated on a schedule, and **never**
written to disk in plaintext, let alone committed. **None of that is happening
here. This is the anti-pattern, on display, with the lights on.**

## Scope of the blast radius (and why it's acceptable *here only*)

- Used **only** inside the throwaway demo cluster you install it into, and
  gone the moment you `helm uninstall`.
- The only data it ever protects is synthetic demo seed data — there is
  nothing of value behind it. Treat this key as public, because it is.
- Its presence is a deliberate, documented friction-vs-correctness trade-off
  for a local demo — not an oversight, and not a recommendation.

## Using a real key instead

The chart uses the baked-in key by default. To override, create
`chart/values-secrets.yaml` with your own and pass it to Helm:

```yaml
pii-tokenizer:
  k_master: "<base64 of 32 random bytes — openssl rand -base64 32>"
```

```bash
helm install ... -f chart/values-demo.yaml -f chart/values-secrets.yaml ...
```

> # ☢️☢️☢️  AGAIN: DO NOT COPY THIS PATTERN  ☢️☢️☢️
