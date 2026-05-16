> # ☢️☢️☢️  DO NOT COPY THIS PATTERN  ☢️☢️☢️
>
> # 🚨🚨🚨  AN UNVERIFIED PROMPT BUNDLE IS COMMITTED HERE ON PURPOSE  🚨🚨🚨

---

## What this is

`bundle.tgz` is a **committed copy of lib-agent-prompt's example prompt
bundle** (schemas + prompt JSON + bundle manifest). The `bundle-fetcher`
pre-install Job extracts it into the `prompt-bundle` PVC that the gateway,
sandbox, and SQL-MCP mount.

It exists for **one reason**: in the real platform this PVC is populated by
**cosign-verifying and pulling the signed `lib-agent-prompt` OCI bundle** —
supply-chain integrity of the prompt/tool contract is a core point of the
whole system. That signed bundle is **not published**, so to keep
`helm install` turnkey we ship an unsigned, unverified fixture instead.

## Why this is NOT how you do it

The entire reason a signed bundle exists is so every component provably runs
the *same, attested* prompt/tool schemas. A committed tarball with no
signature and no verification throws that guarantee away — anyone can swap the
contents and nothing would notice. **This is the anti-pattern, with the lights
on**, exactly like `chart/demo-ca` and `chart/demo-secrets`.

## Extra caveat specific to this one

Unlike the CA and master key (which are correct, just committed), this fixture
is lib-agent-prompt's **example** bundle. It may not exactly match what the
v1.0 consumers expect at runtime. The seed Job is therefore **best-effort and
always exits 0**: if the shape is wrong, the affected component fails on its
own (localized, diagnosable) instead of wedging the whole install at a
pre-install hook.

## The correct fix

Publish the signed `lib-agent-prompt` v1.0 OCI bundle (fix that repo's release
pipeline), then restore the real `bundle-fetcher` that does
`cosign verify … && oras pull …` against it, and delete this directory.

> # ☢️☢️☢️  AGAIN: DO NOT COPY THIS PATTERN  ☢️☢️☢️
