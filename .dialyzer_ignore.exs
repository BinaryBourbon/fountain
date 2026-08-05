# Dialyzer warnings that are understood and deliberately kept, each with its
# reason. Entries are {file, warning_type, location} — pinned to a location so
# a new warning of the same class elsewhere in the file still fails the build.
# The pinned dialyxir ref matches the location term exactly as dialyzer
# reports it: a bare line number when there is no column, or a
# {line, column} tuple when there is.
# If a fix moves the code, the location must move with it; a stale entry
# shows up as an "unnecessary skip" in `mix dialyzer --list-unused-filters`.
[
  # fountain_callback_env/1 guards PUBLIC_URL-derived values with
  # `is_binary(x) and x != ""`. Dialyzer proves the condition always true from
  # today's success typings (PublicUrl.base/0 cannot currently return "") and
  # flags both the comparison and the if's dead else-branch. The guard is
  # defending against operator config, not against types — it stays.
  # The pattern_match arm is reported at line 1 (dialyzer drops the real
  # position for the synthesized boolean pattern), so 1 is the tightest pin
  # available; the exact_compare arm carries a real {line, column}.
  {"lib/fountain/conversations/conversation_server.ex", :pattern_match, 1},
  {"lib/fountain/conversations/conversation_server.ex", :exact_compare, {1404, 64}}
]
