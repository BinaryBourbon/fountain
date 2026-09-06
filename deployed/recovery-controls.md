# Staging recovery controls

These controls support tracker #1617. The public recovery profile is still being
implemented; neither control is registered in the default suite or a canary.
Control-plane evidence alone does not prove transcript, turn, or artifact
recovery. Those assertions must use Fountain's public API.

## Rollout adapter

`adapters/recovery-kubernetes.mjs` exports `RecoveryDeployment`. Its caller first
prepares a durable journal, then calls `roll` during a deterministic turn, and
calls `restore` with a fresh cleanup signal even if the turn or rollout fails.
Keep the journal outside ephemeral CI scratch space until restoration succeeds.

The configuration requires all of these fields:

```json
{
  "adapter": "kubernetes",
  "environment": "staging",
  "base_url": "https://staging.example.test",
  "context": "staging",
  "namespace": "fountain",
  "deployment": "fountain",
  "service": "fountain",
  "container": "fountain",
  "deployment_uid": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "before_image": "registry.example.test/fountain@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "target_image": "registry.example.test/fountain@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "before_digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "target_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "timeout_ms": 300000
}
```

Image references pin the Deployment specification. The separate digests pin the
image identity reported by each serving container; verify these against the
cluster's container runtime before preparing the target. The baseline and target
may be the same image when testing a restart.

The namespace must have label `fountain.dev/environment=staging`. The Deployment
must have label `fountain.dev/recovery-tests=enabled`. Both Deployment and Service
must have annotation `fountain.dev/deployed-suite-base-url` equal to `base_url`.
The adapter reads and validates these settings; it never creates them. The
selected container must already use `before_image`, the Deployment must be
unpaused, and all selected serving endpoints must be healthy at `before_digest`.

Use dedicated cluster credentials with read access to the namespace, Deployment,
Service, pods, ReplicaSets and EndpointSlices, plus patch access to that specific
Deployment. JSON Patch tests the Deployment UID, resource version and selected
container image atomically. This follows Kubernetes' supported
[JSON Patch operation](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/update-api-object-kubectl-patch/).
Namespace and Service identities are checked before mutation and throughout
observation; Kubernetes does not make these separate resource reads atomic with
the Deployment patch.

The adapter changes only the selected container image and the pod-template
annotation `fountain.dev/recovery-run`. The annotation forces a rollout even when
the image is unchanged. Success requires a newer generation, replacement of all
previous serving pod UIDs, and the existing serving-endpoint verifier's readiness,
ownership and digest checks. A patch with a lost response is never retried.

The private journal is synced before mutation and records only selected identity
and revision evidence. Its initial creation is exclusive. Restoration loads fresh
state, restores the baseline image and removes only this run's annotation while
preserving unrelated annotations. It refuses changed ownership, image or resource
identity. An unhealthy target can be rolled back without waiting for it to become
healthy. If a response is lost during restoration, the journal remains usable.

To restore after a process interruption:

```sh
node deployed/recovery-cleanup.mjs --journal /absolute/path/recovery.json
```

This command restores the Deployment and verifies healthy baseline endpoints.
It does not delete public suite fixtures or restore a runner relay lease. Perform
those cleanup steps after connectivity returns. Exit code 3 means restoration
failed; retain the journal and inspect the stated ownership or readiness failure.
There is no command that bypasses ownership checks or runs arbitrary shell input.

## Runner connection relay

`receivers/runner-relay.mjs` forwards a single dedicated runner's
`/api/runners/ws` connection to a fixed HTTPS Fountain origin. Point that runner's
base URL at the relay. Its name and API-key SHA-256 must match the relay's startup
configuration. The key itself is forwarded only to the fixed Fountain origin.
Other API paths, browser origins and runner identities are refused. No request
headers, websocket contents or runner filesystem paths are logged or retained.

Configure:

- `FOUNTAIN_RELAY_UPSTREAM`: staging Fountain HTTPS origin.
- `FOUNTAIN_RELAY_RUNNER_NAME`: dedicated runner name, at most 64 characters.
- `FOUNTAIN_RELAY_RUNNER_KEY_SHA256`: lowercase SHA-256 of its exact API key.
- `FOUNTAIN_RELAY_ADMIN_KEY`: separate credential of at least 32 characters.
- `TLS_CERT_FILE` and `TLS_KEY_FILE`, or `RECEIVER_TLS_AT_INGRESS=true` behind a
  TLS ingress that supports websocket upgrades.
- `PORT`: listener port, default 8080.

Start with `node deployed/receivers/runner-relay.mjs`. The library's explicit
loopback HTTP option exists for local diagnostics and is unavailable through
the executable's environment configuration.

`GET /_suite/identity` reports the version, process instance, upstream and runner
name. Authenticated `PUT /_suite/runs/<UUIDv4>` with
`{"disconnect_ms": 10000}` closes the one active runner socket and refuses
reconnects for that interval. The interval must be 1–60 seconds. An absent runner,
an existing lease, or a repeated run ID is an error. The operation is not retried
and repeated requests cannot extend an outage.

Admission automatically reopens after the interval, including if the suite
process dies. Authenticated `DELETE` of the same run reopens it early and removes
its evidence. Deleting a different run cannot release another run's lease.
Authenticated `GET` returns bounded observations, rejected connection count and
current connection state. At most 32 runs are retained for 15 minutes each, with
64 observations per run; overflow is explicit. Relay shutdown closes its sockets.

The recovery profile must independently observe the same runner becoming offline
and online through Fountain's public API, then verify the accepted turn, replay
and artifact counters. Relay receipts establish the injected network fault only.
Stopping the runner daemon terminates its sessions and is a different scenario.

## Local validation

```sh
node --test deployed/test/recovery-deployment.test.mjs deployed/test/runner-relay.test.mjs
```

The rollout tests apply the actual generated JSON Patch to a simulated API object
and exercise lost responses, concurrent edits, ownership drift and restoration.
The relay tests use real loopback HTTP upgrades and byte forwarding, including
disconnection, automatic reopening and credential isolation. Neither set is a
deployed Fountain recovery verdict.
