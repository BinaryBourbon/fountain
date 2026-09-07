# Changelog

## 0.1.2

- Add typed per-turn execution limits to `Fountain.run`. Unsupported server controls are refused; the preview does not enable bounded execution.

## 0.1.1

- Bound idle stream reads to five seconds so cancellation completes behind a silent proxy.
- Reconnect idle streams from the last complete event and skip status reads after cancellation.

## 0.1.0

- First Python SDK release.
- Run and resume agents, stream turns, and answer permission requests.
- Manage agents, environments, vaults, teammates, schedules, and connections.
