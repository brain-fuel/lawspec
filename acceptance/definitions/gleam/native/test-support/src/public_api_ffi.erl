%% ref:DEC-tests-cite-requirements ref:DEC-total-definitions
-module(public_api_ffi).
-export([catch_error/1]).
catch_error(Run) ->
    try {ok, Run()}
    catch error:{lawspec, {_, {contract_failed, _}}} -> {error, nil};
          error:{lawspec, {integer_out_of_range, _}} -> {error, nil}
    end.
