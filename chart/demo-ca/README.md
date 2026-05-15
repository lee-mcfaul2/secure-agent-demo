> # ☢️☢️☢️  DO NOT COPY THIS PATTERN  ☢️☢️☢️
>
> # 🚨🚨🚨  PRIVATE KEYS ARE COMMITTED TO THIS REPO ON PURPOSE  🚨🚨🚨

---

## What this is

`ca.key`, `ca.crt`, `issuer.key`, `issuer.crt` are a **throwaway Linkerd
identity trust anchor + issuer**, generated once and **committed to version
control in plaintext**, including the private keys.

This exists for **exactly one reason**: to remove friction from `make demo` so
the local KIND demo comes up with a working service mesh in a single command,
without requiring the operator to install cert-manager or run `step`/`openssl`
by hand first.

## Why this is NOT how you do it

Committing a CA private key to a git repository is one of the worst things you
can do to a PKI. Anyone who can read this repo can:

- mint a certificate trusted by every workload in the mesh,
- impersonate any service,
- silently MITM all mesh (mTLS) traffic.

In a real system the Linkerd trust anchor is generated offline and stored in an
HSM/KMS; the issuer is short-lived and rotated automatically by cert-manager.
**None of that is happening here. This is the anti-pattern, on display, with
the lights on.**

## Scope of the blast radius (and why it's acceptable *here only*)

- This CA is **only** trusted inside an ephemeral local KIND cluster you stand
  up on your own machine and tear down with `make demo-down`.
- It is **never** used for anything reachable from outside that local cluster.
- The certs are demo fixtures, not secrets — there is nothing of value behind
  them. Treat them as public, because they are.
- If you are reading this repo: this is a **demonstration of a security
  platform**, not a reference for how to run a CA. The presence of these files
  is a deliberate, documented friction-vs-correctness trade-off for a local
  demo — not an oversight, and not a recommendation.

## If you are tempted to reuse this for anything real

Don't. Regenerate per environment, keep roots offline, rotate issuers
automatically. The commands used to generate these (for reproducibility only):

```sh
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -days 3650 -sha256 -out ca.crt \
  -subj "/CN=root.linkerd.cluster.local" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl ecparam -name prime256v1 -genkey -noout -out issuer.key
openssl req -new -key issuer.key -out issuer.csr \
  -subj "/CN=identity.linkerd.cluster.local"
openssl x509 -req -in issuer.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -sha256 -out issuer.crt \
  -extfile <(printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nextendedKeyUsage=serverAuth,clientAuth")
```

> # ☢️☢️☢️  AGAIN: DO NOT COPY THIS PATTERN  ☢️☢️☢️
