# Published Platform Chart Contract Map (Task 0.1)

Date: 2026-05-16
Author: lee-mcfaul2
Scope: authoritative contract reference for all later Helm-reconstruction tasks.

## Method

- Extracted all 5 published platform charts from `chart/charts/<name>-0.1.0.tgz`
  into `/tmp/pub` (`agent-gateway`, `agent-sandbox`, `llm-guard`,
  `pii-tokenizer`, `agent-sql-mcp`).
- Dumped each chart's `values.yaml`, every env var / `secretKeyRef` /
  `configMapKeyRef` / `secretName` / `configMap` / `claimName`, every
  Service/`containerPort`/`targetPort`, and every Linkerd resource.
- Cross-referenced `chart/values-demo.yaml`,
  `/home/lee/Claude-Playground/ai-security/design-doc.md`,
  `docs/walkthrough.md`, `docs/troubleshooting.md`.
- Confirmed actual Service ports by `helm template`-rendering each published
  chart (no cluster).

Tie-break rule when the design doc is silent:
**"doc silent — tie-break: make walkthrough reproduce."**

## Top-level structural divergence (read this first)

The published charts use **flat** value keys (`.Values.service.port`,
`.Values.oidc.issuer`, `.Values.bundle.ref`, `.Values.llm_guard.base_url`,
`.Values.kmaster.aeadLocal.secretName`, `.Values.database.host`, …).

`chart/values-demo.yaml` sends a **different, mostly richer/nested** shape
(`agent-gateway.litellm.model_list`, `agent-gateway.bundle.pvcName`,
`agent-gateway.llmGuard.baseUrl`, `pii-tokenizer.k_master`,
`agent-sql-mcp.database.password`, `*.namespaceOverride`, `*.service.port`
with different numbers). **Almost none of the nested demo keys are read by the
published charts.** Most demo intent silently no-ops against the published
charts. This is the central reason the demo never installed correctly.

Notable: `agent-sql-mcp` is NOT consumed from the published `.tgz` at all — the
umbrella `Chart.yaml` points it at `file://./charts-local/agent-sql-mcp` (a
patched copy), because the published one is missing its DSN Secret + migrations
ConfigMap. This task still documents the **published** `agent-sql-mcp` contract
(as instructed); the patched local copy is noted where it differs.

Linkerd trust-domain divergence (affects every chart): SPIRE `spiffeIDTemplate`
in `agent-gateway`, `pii-tokenizer`, `agent-sql-mcp` issues
`spiffe://ai-security.io/ns/<ns>/sa/<sa>` (trust domain `ai-security.io`),
but Linkerd `MeshTLSAuthentication` identities mix three incompatible forms:
`agent-sandbox.<ns>.serviceaccount.identity.linkerd.cluster.local` (Linkerd
DNS-style, trust domain `cluster.local`), `spiffe://cluster.local/ns/...`
(llm-guard / agent-sandbox), and `spiffe://ai-security.io/ns/...`
(agent-sql-mcp via `gatewaySPIFFE`). These cannot all authenticate against the
same SPIRE-issued identity. Later Linkerd-identity task must pick ONE trust
domain and make SPIRE issuance + every MeshTLSAuthentication agree.

---

## 1. agent-gateway

Published `values.yaml` is **flat**. Service renders `port: 8000`,
`targetPort: 8000` (the chart's `service.port` default is `8000`; chart does
NOT honor `service.type`/`service.nodePort` — Service has no `type:` field, so
it is always ClusterIP).

| value key the chart reads | default | values-demo currently sends | design doc / walkthrough intends | decision |
|---|---|---|---|---|
| `namespace` | `gateway` | `agent-gateway.namespaceOverride: gateway` (wrong key — chart reads `namespace`, not `namespaceOverride`) | gateway namespace (design §3.1) | keep `gateway`; demo must set `namespace`, not `namespaceOverride` |
| `sandboxNamespace` | `sandbox` | not sent | `sandbox` (design §3.1) | keep `sandbox` |
| `replicas` | `2` | `agent-gateway.replicaCount: 2` (wrong key — chart reads `replicas`) | HA replicas (design §3.1) | set `replicas: 2` |
| `service.port` | `8000` | `8080` (+ `type: NodePort`, `nodePort: 30080`) | walkthrough port-forwards `svc/agent-gateway 8080:8080`; sandbox `litellmUrl` uses `:8080`; gateway_mcp url uses `:8080` | **Service port must be 8080**, targetPort 8000. Chart hardcodes targetPort 8000 and ignores `type`/`nodePort`. Doc/walkthrough want 8080 reachable. tie-break: make walkthrough reproduce → service.port=8080. (NodePort behaviour, if needed, requires a chart change — chart Service has no type.) |
| `oidc.issuer` | `""` | `agent-gateway.oidc.issuer: http://dex.platform.svc.cluster.local:5556/dex` | dex issuer (values-demo) | pass `oidc.issuer` = dex URL |
| `oidc.audience` | `ag-gateway` | `agent-gateway.oidc.audience: demo-ui` | dex staticClient id is `demo-ui` (values-demo) | set `oidc.audience: demo-ui` (chart default `ag-gateway` is wrong for this demo) |
| `tokenizer.url` | `http://pii-tokenizer.platform.svc.cluster.local:8443` | `agent-gateway.tokenizer.baseUrl: ...:8080` (wrong key `baseUrl` vs `url`; wrong port 8080) | pii-tokenizer Service port (see §4): published chart Service is **8443** | keep `tokenizer.url` default `...:8443`; do NOT use demo's `tokenizer.baseUrl`/8080. pii-tokenizer must stay 8443 (see §4 decision) |
| `bundle.ref` | `""` | `agent-gateway.bundle.{pvcName,pvcNamespace,mountPath}` (none of these keys exist in chart) | signed prompt bundle (design §5, demo-bundle) | chart only consumes `bundle.ref` (OCI ref) + cosign secret. The demo's PVC-mount model is unsupported by the published chart. tie-break: make walkthrough reproduce → either set `bundle.ref` to the demo OCI bundle ref, or later task adds PVC support. Flag for bundle/litellm/secret-ref task. |
| `bundle.cosignSecretName` | `gateway-cosign-key` | not sent | cosign pub key (design §5.1/§5.5) | **demo-only Secret required** — see secrets list below |
| `bundle.cosignSecretKey` | `cosign.pub` | not sent | — | keep default |
| `audit.databaseSecretName` | `gateway-audit-db` | not sent | audit log store (design §3.1, §10) | **demo-only Secret required** — see secrets list |
| `audit.databaseSecretKey` | `dsn` | not sent | — | keep default |
| `agentJob.image` | `ghcr.io/lee-mcfaul2/agent-sandbox:0.1.0` | not sent (demo provides `agent-sandbox.podTemplate.*` instead, which this chart never reads) | sandbox image (design §3.2) | keep default or align tag |
| `agentJob.timeoutSeconds` | `300` | not sent | sandbox wall-clock (design §6) | keep `300` |
| `llmProviders.anthropicSecretName` | `gateway-anthropic-key` | not sent | external LLM key (design §6, walkthrough §7) | **demo-only Secret required** (even in ollama/mock mode, secretKeyRef is unconditional → see surprise note) |
| `llmProviders.anthropicSecretKey` | `api-key` | not sent | — | keep default |
| `llmProviders.openaiSecretName` | `gateway-openai-key` | not sent | — | **demo-only Secret required** (unconditional secretKeyRef) |
| `llmProviders.openaiSecretKey` | `api-key` | not sent | — | keep default |
| `llm_guard.enabled` | `true` | `agent-gateway.llmGuard.enabled: true` (wrong key path: chart reads `llm_guard.enabled`, demo sends `llmGuard.enabled`) | walkthrough §3 requires LLM Guard ON (fail-closed; memory ai_security_fail_closed_default) | set `llm_guard.enabled: true` (correct key) |
| `llm_guard.base_url` | `""` | `agent-gateway.llmGuard.baseUrl: http://llm-guard.platform.svc.cluster.local:8000` (wrong key `llmGuard.baseUrl`; **wrong port 8000**) | troubleshooting greps `llm-guard...:8000`; llm-guard Service is **8080** (see §3) | set `llm_guard.base_url` = `http://llm-guard.platform.svc.cluster.local:<llm-guard service.port>`. Port must match §3 decision. Note doc/troubleshooting say `:8000` but published llm-guard Service is `:8080` — conflict, see §3. |
| `llm_guard.timeout_seconds` | `2.0` | not sent | — | keep default |
| `models.default_model` | `claude-sonnet-4-6` | `agent-gateway.models.default_model: claude-sonnet-4-6` | same | OK (key matches) |
| `models.allowed_models` | `"claude-sonnet-4-6,claude-opus-4-7,gpt-4o"` (CSV string) | `agent-gateway.models.allowed_models: [claude-sonnet-4-6, llama3.2]` (**YAML list**, chart wants CSV string) | walkthrough uses local llama via litellm alias `claude-sonnet-4-6` | type mismatch: chart expects comma string, demo sends list. Set `models.allowed_models: "claude-sonnet-4-6,llama3.2"` |
| `gateway_mcp_internal_url` | `http://agent-gateway.gateway.svc.cluster.local:8080` | not sent (demo has `agent-sandbox.podTemplate.litellmUrl`/`mcps` which this chart ignores) | sandbox reaches gateway MCP proxy on `:8080` (design §3.2) | keep default; note default uses `:8080` while Service renders `:8000` unless service.port is fixed → consistency depends on §1 service.port decision |
| `litellm` (any subkey) | NOT a chart value | `agent-gateway.litellm.{mode,model_list}` (large block) | local Ollama routing (values-demo, walkthrough §7) | **Surprise/critical:** the published chart has NO `litellm.*` values. Its `litellm-configmap.yaml` does `{{ .Files.Get "litellm_config.yaml" }}` and **that file is not in the tarball** → ConfigMap `agent-gateway-litellm` renders EMPTY. The entire demo litellm config is dropped. Flag hard for the litellm/bundle/secret-ref task. tie-break: walkthrough §7 must reproduce → chart needs a real litellm config mechanism. |
| `opa.image` / `opa.resources` | `openpolicyagent/opa:1.6.0` / set | not sent | OPA sidecar (design §7) | keep defaults |

Secrets the gateway Deployment requires via `secretKeyRef` but the chart does
NOT create (these become demo-only Secrets in later tasks):
- `gateway-cosign-key` (key `cosign.pub`) — from `bundle.cosignSecretName/Key`
- `gateway-audit-db` (key `dsn`) — from `audit.databaseSecretName/Key`
- `gateway-anthropic-key` (key `api-key`) — from `llmProviders.anthropicSecretName/Key`
- `gateway-openai-key` (key `api-key`) — from `llmProviders.openaiSecretName/Key`

All four `secretKeyRef`s are **unconditional** in `deployment.yaml` (no
`{{- if }}` guard) — the gateway pod will not start until **all four** Secrets
exist, even in ollama/mock mode where the LLM keys are never used.

ConfigMaps the Deployment mounts (chart DOES create `agent-gateway-litellm`,
`agent-gateway-policy`, `agent-gateway-policy-data` via templates — but
`agent-gateway-litellm` is empty, see litellm row above).

Actual Service port: **8000** (rendered). Container port: **8000** (gateway),
**8181** (OPA sidecar). Linkerd `Server` port: **8000**.
RBAC: chart creates a Role/RoleBinding `agent-gateway-job-launcher` in
`sandboxNamespace` allowing the gateway SA to create Jobs/read pods.

Linkerd: `Server agent-gateway` (port 8000) + `AuthorizationPolicy` requiring
`MeshTLSAuthentication agent-sandbox-only` whose identity is
`agent-sandbox.<sandboxNamespace>.serviceaccount.identity.linkerd.cluster.local`
(Linkerd DNS-style, trust domain `cluster.local`). Conflicts with SPIRE
`spiffe://ai-security.io/...` issuance — see top-level Linkerd note.

---

## 2. agent-sandbox

Not a Deployment — ships a **Pod-template ConfigMap**
(`agent-sandbox-job-template`, key `pod-template.yaml`) the gateway's Job
launcher consumes. Flat values; demo sends everything under
`agent-sandbox.podTemplate.*`, almost none of which the chart reads.

| value key the chart reads | default | values-demo currently sends | design doc / walkthrough intends | decision |
|---|---|---|---|---|
| `namespace` | `sandbox` | `agent-sandbox.podTemplate.namespaceOverride: sandbox` (wrong key — chart reads `namespace`) | `sandbox` (design §3.1) | set `namespace: sandbox` |
| `image.repository` | `ghcr.io/lee-mcfaul2/agent-sandbox` | not sent | sandbox image (design §3.2) | keep default |
| `image.tag` | `""` | not sent | always pinned by digest at publish | n/a — chart uses digest |
| `image.digest` | `""` | not sent | signed/pinned digest (design §5.1) | **must set image.digest** — pod-template renders `repo@` (empty digest → invalid image ref `repo@`). Surprise: with default empty digest the rendered pod-template image is `"ghcr.io/lee-mcfaul2/agent-sandbox@"` which is invalid. Flag for image-pinning task. doc silent on exact digest — tie-break: make walkthrough reproduce → pin to the published 0.1.0 digest. |
| `image.pullPolicy` | `IfNotPresent` | not sent | — | keep default |
| `serviceAccount.name` | `agent-sandbox-sa` | not sent | bootstrap SA (design §3.3) | keep default (must match gateway's Linkerd identity for agent-sandbox) |
| `linkerd.trustDomain` | `cluster.local` | not sent | design §3.3 SPIFFE; SPIRE issues `ai-security.io` | **conflict** — see top-level Linkerd note. doc §3.3 implies one trust domain; SPIRE templates use `ai-security.io`. tie-break: pick one in Linkerd task. |
| `linkerd.gateway.namespace` | `gateway` | not sent | egress sandbox→gateway (design §3.1 egress table) | keep `gateway` |
| `linkerd.gateway.serviceAccount` | `agent-gateway-sa` | not sent | — | keep default |
| `resources.{cpu,memory,ephemeralStorage}` | `500m`/`256Mi`/`32Mi` | `agent-sandbox.podTemplate.resources.{requests,limits}` (nested requests/limits — chart wants flat `resources.cpu` etc.) | sandbox limits (values-demo) | type mismatch: chart wants flat `resources.cpu/memory/ephemeralStorage`, demo sends `requests:{}/limits:{}`. Reconcile to flat. |
| `job.activeDeadlineSecondsBuffer` | `30` | not sent | design §6 wall-clock + buffer | keep default |
| `job.ttlSecondsAfterFinished` | `60` | not sent | — | keep default |
| `spire.enabled` | `true` | not sent (top-level `spire.enabled: true` is for the spire subchart, not this) | SPIRE attestation (design §3.3) | keep `true` |
| `gvisor.install` | `false` | not sent | design §3.1 sandbox uses gVisor RuntimeClass | pod-template hardcodes `runtimeClassName: gvisor`; chart only optionally installs the RuntimeClass when `gvisor.install=true`. For demo to schedule, either set `gvisor.install: true` OR a RuntimeClass `gvisor` must exist. doc silent on who installs it for the demo — tie-break: make walkthrough reproduce → set `gvisor.install: true` (or document the dependency). Flag. |
| `agent-sandbox.podTemplate.litellmUrl` | NOT a chart value | `http://agent-gateway.gateway.svc.cluster.local:8080/litellm` | sandbox→gateway litellm proxy (memory ai_security_litellm_uniform_abstraction) | chart's pod-template injects `LITELLM_URL` as `__INJECTED_BY_GATEWAY__` (gateway sets it at Job creation). The demo value is never read by the chart — it must instead be configured on the **gateway** side. Flag for litellm task. |
| `agent-sandbox.podTemplate.mcps.sql.baseUrl` | NOT a chart value | `http://agent-sql-mcp.mcp.svc.cluster.local:8081` | sandbox tool calls go via gateway, not direct to MCP (design §3.2) | not read by chart; also note port `8081` here vs agent-sql-mcp Service `8443` (see §5) — another port divergence. Tool calls route through gateway per design, so this is informational. |

Secrets required via secretKeyRef: **none** (pod-template has no secretKeyRef;
all env are `__INJECTED_BY_GATEWAY__` placeholders).
Ports: pod-template exposes no container port (it is a one-shot Job pod, egress
only). No Service. NetworkPolicy egress: DNS (53) + `linkerd.gateway.namespace`.
Linkerd: `MeshTLSAuthentication agent-sandbox-identity` with identity
`spiffe://<linkerd.trustDomain=cluster.local>/ns/<ns>/sa/<sa>` — note this is
`cluster.local`, but the gateway's policy expects the Linkerd DNS-style name
and SPIRE issues `ai-security.io`. Three-way mismatch — see top-level note.

---

## 3. llm-guard

Flat values + `_helpers.tpl` labels. Service renders `port: 8080`,
`targetPort: http` (named port → containerPort **8080**). Container listens on
`LLM_GUARD_PORT` (set from… see below). `service.port` default `8080`.

| value key the chart reads | default | values-demo currently sends | design doc / walkthrough intends | decision |
|---|---|---|---|---|
| `namespace` | `platform` | `llm-guard.namespaceOverride: platform` (wrong key — chart reads `namespace`) | platform namespace (design §3.1) | set `namespace: platform` |
| `image.repository` | `ghcr.io/lee-mcfaul2/llm-guard` | not sent | — | keep default |
| `image.tag` | `""` (falls back to `.Chart.AppVersion`) | not sent | operator-set per design §5.1 | set `image.tag` (else uses AppVersion) |
| `image.digest` | `""` | not sent | optional pin | keep / pin later |
| `replicaCount` | `2` | `llm-guard.replicaCount: 1` | demo lean | set `replicaCount: 1` (key matches) |
| `service.port` | `8080` | `llm-guard.service.port: 8000` | walkthrough/troubleshooting curl `llm-guard.platform.svc...:8000`; gateway demo `llmGuard.baseUrl` uses `:8000` | **CONFLICT — must tie-break.** Published chart Service+container is 8080 (`targetPort: http`→containerPort 8080). Every doc reference (walkthrough §3 indirectly, troubleshooting explicit `curl ...:8000/healthz`) and the gateway demo config say 8000. Decision: **set `llm-guard.service.port: 8000`** so the documented walkthrough/troubleshooting reproduce; the gateway `llm_guard.base_url` must use the SAME port (8000). The container's named `http` port stays 8080 internally; Service `port: 8000 → targetPort http(8080)` works. tie-break basis: make walkthrough reproduce (docs explicitly say 8000). Flag for ports task. |
| `config.inbound_scanners` | `prompt_injection,secrets,ban_substrings,toxicity,ban_topics` | demo sends `scanners.{promptInjection,toxicity,secrets}` (entirely different shape — chart reads `config.inbound_scanners` CSV) | walkthrough §3 needs prompt_injection ON | demo's `scanners.*` block is not read. Keep chart default CSV (already includes prompt_injection) OR map demo intent into `config.*`. Decision: rely on `config.*` defaults (prompt_injection present). |
| `config.outbound_scanners` etc. | set (see values) | not sent (demo `failClosed`, `scanners.*` not read) | scrub secrets/codewords (memory ai_security_redesign) | keep defaults |
| `config.*_block_threshold` | set | demo `scanners.*.threshold` (not read) | thresholds (values-demo) | keep chart defaults; demo thresholds silently ignored — note for parity, low priority |
| `piiTypes.content` | `{ "categories": [] }` (inline JSON) | `llm-guard.piiTypes.{configMapName: pii-types, mountPath}` (chart has NO configMapName/mountPath keys; it inlines `piiTypes.content` into its own ConfigMap) | mount platform pii-types ConfigMap from lib-agent-prompt (values-demo, design §5.5) | **Surprise:** chart self-creates `configmap-pii-types.yaml` from `piiTypes.content`; it cannot mount an external `pii-types` ConfigMap. Demo's `configMapName`/`mountPath` are dropped. Also: deployment env `LLM_GUARD_PII_TYPES_PATH` is set but the chart's deployment does NOT mount the pii-types ConfigMap as a volume (template references `configMap:` volume but value source is the self-made CM). Verify in pii-types/llm-guard task. doc silent on exact pii-types content for demo — tie-break: make walkthrough reproduce. |
| `linkerd.trustDomain` | `cluster.local` | not sent | design §3.3 | conflict — see top-level Linkerd note |
| `linkerd.gateway.namespace` | `gateway` | `llm-guard.networkPolicy.allowedNamespaces: [gateway]` (different key; chart uses `linkerd.gateway.namespace` for NetworkPolicy + meshtls) | only gateway may call llm-guard (values-demo, design §3.1) | chart already restricts to `linkerd.gateway.namespace=gateway`; demo's `networkPolicy.allowedNamespaces` not read. Default already correct. |
| `linkerd.gateway.serviceAccount` | `agent-gateway-sa` | not sent | — | keep default |
| `prometheus.serviceMonitor.enabled` | `true` | `llm-guard.serviceMonitor.{enabled,namespace}` (chart reads `prometheus.serviceMonitor.enabled`; no `namespace` key) | dashboards (walkthrough §5) | set `prometheus.serviceMonitor.enabled: true`; demo's `serviceMonitor.namespace` not read |
| `spire.enabled` | `true` | not sent | SPIRE (design §3.3) | keep `true` |
| `resources.*` | set | `llm-guard.resources.{requests,limits}` (shape matches chart) | values-demo | OK (matches) |

Secrets required via secretKeyRef: **none**.
`LLM_GUARD_PORT` env: set from `{{ .Values.service.port }}`? — confirm in
llm-guard task; deployment env block sets `LLM_GUARD_PORT` (value source line
truncated in grep but follows the `service.port` pattern). The container's
named port `http` is **8080** regardless. **Port consistency risk**: if
`service.port` is overridden to 8000 but `LLM_GUARD_PORT` is also bound to
`service.port`, the container would listen on 8000 while the named `http` port
(targetPort) is declared 8080 → broken. The ports task MUST verify what
`LLM_GUARD_PORT` is wired to and ensure container listen port == declared
containerPort (`http`/8080) while Service `port` is the externally documented
8000. Flag explicitly.
Actual Service port: rendered **8080** (default). Container port: **8080**
(named `http`). Linkerd `Server llm-guard` port: `http`.
Linkerd: `MeshTLSAuthentication agent-gateway-mtls` identity
`spiffe://<trustDomain=cluster.local>/ns/<gateway.namespace>/sa/<gateway.sa>`
(SPIFFE-style, `cluster.local`). AuthorizationPolicy
`llm-guard-allow-gateway`. Differs from gateway's own Linkerd DNS-style form
and SPIRE `ai-security.io` — see top-level note.

---

## 4. pii-tokenizer

Flat values. Service renders `port: 8443`, `targetPort: 8443`,
containerPort **8443**, `TOKENIZER_LISTEN_ADDR=":8443"` (hardcoded in env).
`service.port` default `8443`.

| value key the chart reads | default | values-demo currently sends | design doc / walkthrough intends | decision |
|---|---|---|---|---|
| `namespace` | `platform` | `pii-tokenizer.namespaceOverride: platform` (wrong key — chart reads `namespace`) | platform (design §3.1) | set `namespace: platform` |
| `image.repository` | `ghcr.io/lee-mcfaul2/pii-tokenizer` | not sent | — | keep default |
| `image.tag` | `0.1.0` | not sent | — | keep default |
| `replicas` | `2` | `pii-tokenizer.replicaCount: 1` (wrong key — chart reads `replicas`) | demo lean (1) | set `replicas: 1` |
| `service.port` | `8443` | `pii-tokenizer.service.port: 8080` | gateway `tokenizer.url` default is `...:8443`; container hardcodes `:8443`; Linkerd Server port 8443 | **CONFLICT.** Container listens on `:8443` (hardcoded env, not value-driven), Service targetPort hardcoded 8443, Linkerd Server 8443. Demo sends `8080` and demo gateway `tokenizer.baseUrl` also `8080` — but the gateway chart's actual `tokenizer.url` default is `8443`. Design §3.2/§5.4 only says "Tokenizer reachable only by gateway", port unspecified. Decision: **keep pii-tokenizer Service port 8443** (changing it to 8080 would mismatch the hardcoded container listen addr + targetPort + Linkerd Server). Gateway `tokenizer.url` must therefore be `...:8443` (chart default — do NOT use demo's 8080). doc silent on port — tie-break: make walkthrough reproduce → 8443 end-to-end. Flag for ports task: drop demo's `pii-tokenizer.service.port: 8080` and `agent-gateway.tokenizer.baseUrl ...:8080`. |
| `kmaster.backend` | `aead-local` | not sent (demo sends `pii-tokenizer.k_master: <base64>`) | demo-only baked AES key (values-demo, demo-secrets/README) | keep `aead-local` |
| `kmaster.aeadLocal.secretName` | `pii-tokenizer-kmaster` | not sent | the k_master must land in a Secret named here (design §5.4, §6 K_master) | chart mounts Secret `pii-tokenizer-kmaster` at `/etc/tokenizer/kmaster`; **demo's `k_master` value is never written into that Secret by the published chart.** See ordering surprise below. |
| `kmaster.vault/awsKms/pkcs11.*` | unset | not sent | prod backends | n/a for demo |
| `redis.mode` | `single` | `pii-tokenizer.redis.{enabled,persistence}` (chart reads `redis.mode`/`redis.addrs`; no `enabled`/`persistence` keys) | Redis-backed state (design §5.4, §13.x) | demo's redis block not read. Keep `redis.mode: single`, `redis.addrs` default. Note: chart assumes a Redis at `redis.platform.svc.cluster.local:6379` exists — the demo must provide one (values-demo's `pii-tokenizer.redis.enabled: true` does NOT create Redis here). Flag: who provisions Redis? doc silent — tie-break: walkthrough must reproduce → a Redis service must exist at the default addr. |
| `redis.addrs` | `redis.platform.svc.cluster.local:6379` | not sent | — | keep default; ensure a matching Redis Service exists |
| `initKMaster` | `true` | not sent | turnkey key init (demo-secrets/README) | keep `true` BUT see surprise: the init Job does NOT create the Secret |

**pii-tokenizer kmaster ordering — critical (for the kmaster-ordering task):**
- Deployment unconditionally mounts Secret `pii-tokenizer-kmaster` (volume
  `kmaster`, projected at `/etc/tokenizer/kmaster`) when
  `kmaster.backend == aead-local`. Pod will not start until that Secret exists.
- The published `secret-init-job.yaml` is a `post-install` hook that runs
  `rotate-kmaster init -o /workdir` into an **emptyDir** and literally prints
  *"Apply the Secret manually OR use a sidecar that writes via kubectl."* — it
  **never creates the `pii-tokenizer-kmaster` Secret**. So: (a) the Deployment
  blocks on a missing Secret, and (b) the init Job is post-install (runs AFTER
  the Deployment) and is a no-op anyway.
- The demo's intent is a baked key (`pii-tokenizer.k_master` in values-demo,
  `chart/demo-secrets/k_master.txt`). Nothing in the published chart turns that
  value into the `pii-tokenizer-kmaster` Secret.
- Decision / hand-off to kmaster-ordering task: the demo must create the
  `pii-tokenizer-kmaster` Secret (key path = `/etc/tokenizer/kmaster`; chart
  env `TOKENIZER_AEAD_KEY_PATH=/etc/tokenizer/kmaster`) from the baked
  `k_master` BEFORE the Deployment starts (umbrella-level template or a
  pre-install hook), and `initKMaster` should be `false` (the published init
  Job is useless and post-install). doc silent on mechanism — tie-break: make
  walkthrough reproduce (turnkey, no manual `kubectl apply`).

Secrets required via secretKeyRef/volume but NOT created by the chart:
- `pii-tokenizer-kmaster` (mounted as volume, not secretKeyRef) — **demo-only
  Secret required**; must contain the AEAD key file consumed at
  `/etc/tokenizer/kmaster`.
Actual Service port: **8443**. Container port: **8443** (hardcoded listen
addr). Linkerd `Server pii-tokenizer` port **8443**.
Linkerd: `MeshTLSAuthentication agent-gateway-only` identity
`agent-gateway.gateway.serviceaccount.identity.linkerd.cluster.local`
(**Linkerd DNS-style, hardcoded `gateway` ns + `cluster.local`** — not
templated, ignores any namespace override). AuthorizationPolicy
`pii-tokenizer`. RBAC: Role/RoleBinding granting the tokenizer SA `get` on the
named kmaster Secret. SPIRE issues `spiffe://ai-security.io/...`. Mismatch with
the DNS-style hardcoded identity — see top-level Linkerd note; the gateway's
SPIRE identity (`ai-security.io`) will NOT match
`agent-gateway.gateway.serviceaccount.identity.linkerd.cluster.local`.

---

## 5. agent-sql-mcp (PUBLISHED chart — note: umbrella uses charts-local/ copy instead)

Flat values. Service renders `port: 8443`, `targetPort: 8443`,
containerPort **8443**, `SQLMCP_LISTEN_ADDR=":8443"` hardcoded.
`service.port` default `8443`.

| value key the chart reads | default | values-demo currently sends | design doc / walkthrough intends | decision |
|---|---|---|---|---|
| `namespace` | `mcp` | `agent-sql-mcp.namespace: mcp` | mcp namespace (design §3.1) | OK (key matches) |
| `replicas` | `2` | `agent-sql-mcp.replicas: 1` | demo lean | OK |
| `oidc.issuer` | `""` | `agent-sql-mcp.oidc.issuer: http://dex...:5556/dex` | dex (values-demo) | set issuer (key matches) |
| `oidc.audience` | `agent-sql-mcp` | `agent-sql-mcp.oidc.audience: demo-ui` | dex client id `demo-ui` | set `oidc.audience: demo-ui` (default `agent-sql-mcp` wrong for demo) |
| `gatewaySPIFFE` | `spiffe://ai-security.io/ns/gateway/sa/agent-gateway-sa` | not sent | gateway SPIFFE (design §3.3) | keep default — uses trust domain `ai-security.io` (consistent with SPIRE templates, but inconsistent with gateway/pii-tokenizer/llm-guard Linkerd `cluster.local` forms — see top-level note) |
| `database.secretName` | `agent-sql-mcp-db` | demo sends `agent-sql-mcp.database.{host,port,user,name,password,sslmode}` (plain parts) | DSN for customer-db (values-demo, design §10) | **Surprise:** published chart consumes only `database.secretName`/`secretKey` (a pre-existing DSN Secret) via secretKeyRef in deployment, migration-job, AND audit-retention-cronjob — but the published chart **never creates** that Secret, and does NOT read `database.host/user/password/...`. The demo's plain parts are dropped. This is exactly why the umbrella uses `charts-local/agent-sql-mcp` (which DOES assemble the DSN Secret from the plain parts and adds a migrations ConfigMap + a `waitImage` initContainer). Decision: for published-chart contract, `agent-sql-mcp-db` (key `dsn`) is a required, uncreated Secret. The reconstruction uses the local patched chart instead; ensure values-demo's `agent-sql-mcp.database.*` matches the **local** chart's keys (it does: local chart adds `host/user/name/password`). |
| `database.secretKey` | `dsn` | not sent | — | keep `dsn` |
| `database.poolMax` / `queryTimeoutSeconds` | `25` / `5` | not sent | design §7 | keep defaults |
| `schemaVersion` | `v1` | not sent | schema handshake (design §5.6, memory ai_security_schema_versioning) | keep `v1` |
| `service.port` | `8443` | `agent-sql-mcp.service.port: 8443` | demo sandbox `mcps.sql.baseUrl` uses `:8081` (mismatch, but tool calls route via gateway per design §3.2 so informational) | keep `8443` (matches container hardcoded listen + Linkerd Server). Note demo sandbox `:8081` ref is dead (chart not read by sandbox anyway). |
| `audit.retentionDays` | `90` | not sent | design §10 audit retention | keep `90` |
| `migrations.image` | `migrate/migrate:v4.18.1` | not sent | DB migrations | keep default; **published chart references ConfigMap `agent-sql-mcp-migrations` (volume in migration-job) but never creates it** — another reason charts-local/ is used. |

Secrets required via secretKeyRef but NOT created by published chart:
- `agent-sql-mcp-db` (key `dsn`) — referenced by Deployment, migration-job,
  AND audit-retention-cronjob. **demo-only Secret required** (the local patched
  chart assembles it from `database.host/port/user/name/password/sslmode`).
ConfigMaps referenced but NOT created by published chart:
- `agent-sql-mcp-migrations` (mounted by `migration-job.yaml`) — missing in
  published chart; provided by charts-local/ copy.
Actual Service port: **8443**. Container port: **8443**. Linkerd `Server
agent-sql-mcp` port **8443**.
Linkerd: `MeshTLSAuthentication agent-gateway-only` identity = `{{ .Values.gatewaySPIFFE }}`
= `spiffe://ai-security.io/ns/gateway/sa/agent-gateway-sa` (trust domain
`ai-security.io`). This is the ONLY chart whose Linkerd identity matches the
SPIRE `spiffeIDTemplate` trust domain (`ai-security.io`). gateway/pii-tokenizer
use Linkerd DNS-style `cluster.local`; llm-guard/agent-sandbox use
`spiffe://cluster.local`. See top-level Linkerd note — the platform cannot have
the gateway present two different SPIFFE identities; the Linkerd-identity task
must unify.

---

## Cross-cutting hand-offs for later tasks

### Linkerd identity task
- SPIRE `spiffeIDTemplate` issues `spiffe://ai-security.io/ns/<ns>/sa/<sa>` in
  agent-gateway, pii-tokenizer, agent-sql-mcp.
- `MeshTLSAuthentication` identities are inconsistent across charts:
  - agent-gateway authz expects sandbox as Linkerd DNS-style
    `agent-sandbox.<ns>.serviceaccount.identity.linkerd.cluster.local`.
  - agent-sandbox presents `spiffe://cluster.local/ns/<ns>/sa/<sa>`.
  - llm-guard expects gateway as `spiffe://cluster.local/ns/gateway/sa/agent-gateway-sa`.
  - pii-tokenizer expects gateway as Linkerd DNS-style **hardcoded**
    `agent-gateway.gateway.serviceaccount.identity.linkerd.cluster.local`
    (namespace not templated).
  - agent-sql-mcp expects gateway as `spiffe://ai-security.io/ns/gateway/sa/agent-gateway-sa`.
- One workload (the gateway) cannot simultaneously be
  `spiffe://ai-security.io/...`, `spiffe://cluster.local/...`, and the Linkerd
  DNS-style `cluster.local` name. Pick ONE trust domain (design §3.3 + memory
  ai_security_mtls_everywhere imply SPIFFE-keyed; SPIRE templates already use
  `ai-security.io`) and rewrite every `MeshTLSAuthentication` + SPIRE template
  to agree. doc silent on the literal string — tie-break: make walkthrough
  reproduce.

### pii-tokenizer kmaster ordering task
- Deployment hard-mounts Secret `pii-tokenizer-kmaster` at
  `/etc/tokenizer/kmaster` (env `TOKENIZER_AEAD_KEY_PATH` matches).
- Published `secret-init-job` is a post-install no-op that never creates it.
- Demo intent: baked `pii-tokenizer.k_master` / `chart/demo-secrets/k_master.txt`.
- Need: create the Secret from the baked key BEFORE the Deployment, set
  `initKMaster: false`.

### gateway litellm / bundle / secret-ref task
- Published gateway has NO `litellm.*` values; `agent-gateway-litellm`
  ConfigMap renders EMPTY (`.Files.Get "litellm_config.yaml"` — file absent
  from tarball). All of values-demo's `agent-gateway.litellm.*` is dropped.
- Gateway `bundle.*` chart contract is OCI-ref + cosign Secret; demo's
  PVC-mount model (`bundle.pvcName/pvcNamespace/mountPath`) is unsupported.
- 4 unconditional `secretKeyRef`s (`gateway-cosign-key`, `gateway-audit-db`,
  `gateway-anthropic-key`, `gateway-openai-key`) block startup even in
  ollama/mock mode and none are created by any chart.
- Wrong demo key paths: `llmGuard.*` vs chart `llm_guard.*`;
  `tokenizer.baseUrl` vs chart `tokenizer.url`; `replicaCount` vs `replicas`;
  `namespaceOverride` vs `namespace`; `models.allowed_models` list vs CSV.

### ports task
- agent-gateway Service: chart renders **8000**; walkthrough/sandbox/mcp-url
  expect **8080**. Chart hardcodes targetPort 8000 and has no Service `type`
  (NodePort impossible without chart change). Decision: Service port 8080,
  targetPort 8000; NodePort needs a chart edit if required.
- llm-guard Service: chart renders **8080**; docs/troubleshooting/gateway
  config say **8000**. Decision: set `llm-guard.service.port: 8000` (Service
  port 8000 → targetPort named `http`/8080). Verify `LLM_GUARD_PORT` wiring so
  the container keeps listening on 8080 (the declared containerPort), not
  whatever `service.port` becomes.
- pii-tokenizer: container/targetPort/Linkerd all hardcoded **8443**. Keep
  Service 8443; drop demo's `service.port: 8080` and gateway's `:8080`
  tokenizer ref; gateway `tokenizer.url` must be `...:8443`.
- agent-sql-mcp: all **8443**; demo sandbox `:8081` ref is dead (routing is via
  gateway per design §3.2).

### agent-sql-mcp note
- The umbrella `Chart.yaml` deliberately points agent-sql-mcp at
  `file://./charts-local/agent-sql-mcp`, NOT the published `.tgz`, because the
  published chart is missing the DSN Secret and migrations ConfigMap. Later
  tasks should treat charts-local/agent-sql-mcp as the source of truth for that
  component; this map documents the published chart's contract as instructed
  for completeness and to justify the override.
