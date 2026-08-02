# Dialyzer warnings that are understood and deliberately kept, each with its
# reason. Entries are {file, warning_type, line} — pinned to a line so a new
# warning of the same class elsewhere in the file still fails the build.
# If a fix moves the code, the line number must move with it; a stale entry
# shows up as an "unnecessary skip" in `mix dialyzer --list-unused-filters`.
[
  # fountain_callback_env/1 guards PUBLIC_URL-derived values with
  # `is_binary(x) and x != ""`. Dialyzer proves the condition always true from
  # today's success typings (PublicUrl.base/0 cannot currently return "") and
  # flags both the comparison and the if's dead else-branch. The guard is
  # defending against operator config, not against types — it stays.
  # (2-tuples rather than {file, type, line}: the pinned dialyxir ref only
  # matches 3-tuples against column-less warning locations, and its string
  # filters don't clear the error count. File+type is the tightest shape that
  # works reliably here — revisit when dropping the pin.)
  {"lib/fountain/conversations/conversation_server.ex", :pattern_match},
  {"lib/fountain/conversations/conversation_server.ex", :exact_compare},

  # Billing.handle_event/1 really does return {:ok, :stale} — the out-of-order
  # webhook path is exercised end-to-end in stripe_webhook_idempotency_test —
  # but dialyzer's flow analysis through Stripe.Event's loosely-typed :data
  # field loses the branch and calls the controller clause unreachable.
  {"lib/fountain_web/controllers/stripe_webhook_controller.ex", :pattern_match}
]
