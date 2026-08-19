# Fountain plugin for Hermes Agent

Run [Fountain](https://github.com/BinaryBourbon/fountain) agents as tools from
[Hermes Agent](https://github.com/NousResearch/hermes-agent). Hermes gets
`fountain_run` and friends; the work runs in a Fountain sandbox.

The user-facing page is [`docs/integrations/hermes.md`](../../docs/integrations/hermes.md).
This directory is the plugin itself plus its tests.

```
integrations/hermes/
├── fountain/                 the plugin — install this directory
│   ├── plugin.yaml           manifest (v2): tools, config_schema
│   ├── __init__.py           register(ctx): tools, skill, /fountain command
│   ├── client.py             stdlib HTTP client + credential resolution
│   ├── tools.py              handlers; follows a turn through /events?blocks=true
│   ├── schemas.py            tool schemas (what the model sees)
│   └── skills/fountain/SKILL.md
└── tests/                    unittest, against an in-process fake Fountain
```

## Install

```bash
hermes plugins install BinaryBourbon/fountain/integrations/hermes/fountain --enable
# or, from a checkout:
ln -s "$PWD/integrations/hermes/fountain" ~/.hermes/plugins/fountain && hermes plugins enable fountain
```

Credentials resolve like the `fountain` CLI: `FOUNTAIN_API_KEY` (or the
in-sandbox `FOUNTAIN_TOKEN`), then `~/.fountain/credentials` (written by
`fountain auth login`). `FOUNTAIN_BASE_URL` points at a self-hosted instance.
Both can also be pinned in Hermes config under
`plugins.entries.fountain.settings` (`base_url`, `api_key`, `profile`,
`default_timeout_seconds`).

## Test

```bash
python3 -m unittest discover -s integrations/hermes/tests -v   # from the repo root
hermes plugins doctor integrations/hermes/fountain              # with a Hermes checkout
```

No dependencies: the plugin and its tests are stdlib Python ≥ 3.9 (Hermes
itself needs 3.11).
