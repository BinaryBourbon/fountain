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
Mimic.copy(Stripe.Webhook)
Mimic.copy(Stripe.Customer)
Mimic.copy(Stripe.BillingPortal.Session)
Mimic.copy(Stripe.Checkout.Session)

Mimic.copy(Fountain.Conversations.ConversationServer)
Mimic.copy(Fountain.Accounts)
Mimic.copy(Fountain.Audit)
Mimic.copy(Fountain.Crypto)
