%% The header's extra field proves record offsets come from the Erlang compiler.
-record(wrapped, {audit = retained, stored}).
-record(seal, {}).
