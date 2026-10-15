# Native set generation

The native property frameworks generate and shrink Boolean, nested, empty,
Unit, Maybe Bool, Float64 and Symbol sets. Duplicate equal members retain
their first stored representation; generation invokes no portable order.
The same native map transforms each shrink, and existing checked schema and
input predicates reject any candidate or shrink outside its dependent domain.
User-supplied native factories remain validated without repair.

Ten laws run with property and example checking selected. Eight reuse the
finite-domain fixture, including its dependent pairs. Two further laws check
IEEE insertion/membership and Symbol identity over unbounded inputs. Four
explicit IEEE/Symbol examples independently pin NaNs, signed zeros and symbols
with matching descriptions. These sampled results do not prove universal laws. A complete singleton input
is executed once instead of requesting distinct random samples.

The dependent-size mutant agrees with paired boundary inputs but rejects
admitted unequal-size pairs. A valid minimal failure has a singleton left set
and an empty right set; shrinking must keep the right-size restriction true.
The large-set mutant agrees with the fixed boundary sets (at most two members)
but fails for generated Float64 sets above eight members. Its failure therefore
reaches the native property framework and its shrinking path. Complete schema
and dependent input checks remain in force for candidates and shrinks.

Run `lawspec-acceptance rc1-set-generation [target...]`. Set
`LAWSPEC_MACHINE_BITS=32 LAWSPEC_MINIFY=1` for the compact 32-bit profile.
