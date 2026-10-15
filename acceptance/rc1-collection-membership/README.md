# Finite collection membership and predicates

Twenty laws cover List, Set, SortedSet, Queue, Stack, Deque, bytes,
explicit map keys/values/entries and the checked item operations of sized
stacks and queues. Membership uses element Eq. Predicates use the existing
checked element iteration, preserve strict captured arguments and require no
extra equality. Floating literals inherit their element context; IEEE NaNs
and signed zeros retain language equality. Checked definitions, nested
membership and ordinary names exercise independent callback scopes.

Six independent table rows include membership, predicates and signed zero.
Three expectation mutants compile and must fail during native test execution.
They do not alter the authoritative laws or their complete finite results.

Run `lawspec-acceptance rc1-collection-membership [target...]` and repeat with
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
