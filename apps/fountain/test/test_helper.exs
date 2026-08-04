ExUnit.start()

# Only set sandbox mode when the Repo is actually running (integration tests).
# Pure unit tests that don't touch the DB can run without a live Postgres.
if Process.whereis(Fountain.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :manual)
end

# Mimic copies modules so tests can stub/expect their functions without
# requiring us to wrap sprites-ex in an adapter behaviour.
Mimic.copy(Sprites)
Mimic.copy(Sprites.Filesystem)
Mimic.copy(Fountain.SpritesClient)
Mimic.copy(Horde.DynamicSupervisor)
Mimic.copy(Req)

# Stripe modules — needed by billing tests and webhook controller tests.
# Billing itself is copied so the webhook controller's :retry/500 arm can be
# driven with an injected transient failure — there is no real Stripe outage
# to reproduce in a test.
Mimic.copy(Fountain.Billing)
Mimic.copy(Stripe.Webhook)
Mimic.copy(Stripe.Customer)
Mimic.copy(Stripe.BillingPortal.Session)
Mimic.copy(Stripe.Checkout.Session)
Mimic.copy(Stripe.Subscription)
Mimic.copy(Fountain.SpritesClient)

Mimic.copy(Fountain.Conversations.ConversationServer)
Mimic.copy(Fountain.Conversations.Provisioning)
Mimic.copy(Fountain.SpriteSkills)
Mimic.copy(Fountain.Accounts)
Mimic.copy(Fountain.Audit)
Mimic.copy(Fountain.Crypto)
Mimic.copy(Fountain.Health)
Mimic.copy(FountainWeb.OAuth)
Mimic.copy(Fountain.Mailer)
Mimic.copy(Fountain.Workers.LifecycleEmail)
Mimic.copy(Fountain.InferenceCredentials)
