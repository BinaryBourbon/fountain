# Put it on the internet

This guide shows you how to expose an instance safely, once it runs locally.

The compose file publishes port 4000 with no TLS. Terminate TLS in front of it
with Caddy, nginx, or a tunnel.

## Before you start

Register your own account first. While no admin exists, the first verified
account gets the role, so an open instance with no admin is an instance anyone
can take.

## Set three variables

- `PUBLIC_URL`, the external URL with scheme included. It builds verification
  links and is passed to every sandbox.
- `TRUSTED_PROXIES`, your proxy's address range. Without it, per-IP rate limits
  all collapse into one bucket keyed on the proxy.
- `REGISTRATION_ENABLED=false`, or set `REGISTRATION_ALLOWED_EMAIL_DOMAINS`.

Registration is open by default. An instance on the public internet with
registration open will be found.

## What an https PUBLIC_URL switches on

An `https://` `PUBLIC_URL` also enables HTTPS redirection, HSTS (one year,
including subdomains, not preloaded) and the `secure` flag on the session
cookie.

All three are derived from the scheme rather than set separately, because none
of them can be on for an `http://` instance. A cookie marked secure is never
sent back, and the redirect would point at a port serving nothing.

If you terminate TLS in front of Fountain, make sure your proxy sets
`X-Forwarded-Proto`. The redirect uses it, and without it every request looks
like plain http and loops.

`CHECK_ORIGIN_EXTRA` adds origins allowed to open a LiveView websocket, as a
comma-separated list. Your own host is always included, so add to this only for
something like a preview environment on a different domain.

## Verify it worked

```bash
curl -sSI https://your-fountain.example.com/health/ready | head -1
```

Then sign in through the public URL. A redirect loop in the browser means the
proxy is not setting `X-Forwarded-Proto`.

## If it did not work

See [Pods restarting or not ready](../../troubleshooting/pods-restarting.md)
for the probe-versus-redirect interaction, which is the other common surprise
here. `/health` and `/health/ready` are exempt from the https redirect
precisely because probes hit the pod over plain http.

## Related

- [Deploy an instance](deploy.md).
- [Observability](observability.md), including the health endpoints.
- [Configuration reference](../../configuration.md).
