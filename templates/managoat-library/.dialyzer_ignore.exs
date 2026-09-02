# Dialyzer warnings that are understood and deliberately kept, each with its
# reason. Entries are {file, warning_type, location}.
#
# Prefer `@dialyzer {:nowarn_function, name: arity}` beside the function: a
# location pin here is only stable while nothing above it in the file moves.
# Reach for this file when the warning has no single owning function, or when
# the code is inside a dependency. A stale entry shows up in
# `mix dialyzer --list-unused-filters`.
[]
