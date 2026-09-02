ExUnit.start()

# `mix test` at the umbrella root runs every app's suite in one VM, and
# apps/managoat_runner/test/test_helper.exs names Managoat.Runner.Host.Local
# as the runner host (the library has no config of its own, and no default
# host on purpose). Application env survives into this run, so name
# Fountain's host again here or every runner-presence test sees a daemon
# registered in a Registry that Fountain.Runners never looks in. Same value
# as config/config.exs; a no-op when this suite runs on its own.
Application.put_env(:managoat_runner, :host, Fountain.Runners.Host)

# Only set sandbox mode when the Repo is actually running (integration tests).
# Pure unit tests that don't touch the DB can run without a live Postgres.
if Process.whereis(Fountain.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :manual)
end

# Mimic copies modules so tests can stub/expect their functions. The sandbox
# seam is Managoat.Sandbox.Sprites (the adapter behind the Managoat.Sandbox
# facade, from apps/managoat_sandbox); the raw SDK copies below it exist for
# the full-stack provisioning/checkpoint pins. The adapters' own unit tests
# live in the library and copy what they stub in its test_helper.
Mimic.copy(Managoat.Sandbox)
Mimic.copy(Managoat.Sandbox.Sprites)
Mimic.copy(Fountain.AvatarGenerator)
Mimic.copy(Managoat.Sandbox.Sprites.Client)
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(Horde.DynamicSupervisor)
# Horde.Registry is copied so the registry settle window (#800) can be driven
# from a test rather than waited out: a stub decides which poll finds the
# server, which is what stops that test racing a loaded runner (#921).
Mimic.copy(Horde.Registry)
Mimic.copy(Req)

# Stripe modules — needed by billing tests and webhook controller tests.
# Billing itself is copied so the webhook controller's :retry/500 arm can be
# driven with an injected transient failure — there is no real Stripe outage
# to reproduce in a test.
Mimic.copy(Fountain.Billing)
Mimic.copy(Stripe.Webhook)
Mimic.copy(Stripe.Customer)
Mimic.copy(Stripe.Checkout.Session)

Mimic.copy(Fountain.Conversations.ConversationServer)
Mimic.copy(Fountain.Conversations.TitleGenerator)
Mimic.copy(Fountain.Conversations.Provisioning)
Mimic.copy(Fountain.Broker)
Mimic.copy(Fountain.SandboxSkills)
Mimic.copy(Fountain.Accounts)
Mimic.copy(Fountain.Audit)
Mimic.copy(Fountain.Crypto)
Mimic.copy(Fountain.Health)
Mimic.copy(FountainWeb.OAuth)
Mimic.copy(Fountain.Mailer)
Mimic.copy(Fountain.InferenceCredentials)
