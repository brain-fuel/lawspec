%% ref:REQ-law-primitives ref:REQ-harness-units
-module(example_shared_peer).
-export([open_pool/1, reset_pool/1, close_pool/1, use_pool/1]).
open_pool(Unit) -> beam_shared_resource_support:open_pool(Unit).
reset_pool(Pool) -> beam_shared_resource_support:reset_pool(Pool).
close_pool(Pool) -> beam_shared_resource_support:close_pool(Pool).
use_pool(Pool) -> beam_shared_resource_support:use_pool(Pool).
