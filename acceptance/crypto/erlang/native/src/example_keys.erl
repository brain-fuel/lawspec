-module(example_keys).
-export([counting_signer/0, counting_exchange/0]).

counting_signer() ->
    #{signing_key_pair := Make, sign := Sign, verify := Verify} = lawspec_crypto:signature_handler(),
    Count = lawspec_beam_effects:native_cell(0),
    #{signing_key_pair => Make,
      sign => fun(Key, Message) -> increment(Count), Sign(Key, Message) end,
      verify => fun(Key, Message, Signature) -> Verify(Key, Message, Signature) end}.

counting_exchange() ->
    #{exchange_key_pair := Make, encapsulate := Encapsulate, decapsulate := Decapsulate} = lawspec_crypto:key_exchange_handler(),
    Count = lawspec_beam_effects:native_cell(0),
    #{exchange_key_pair => Make,
      encapsulate => fun(Key) -> increment(Count), Encapsulate(Key) end,
      decapsulate => fun(Key, Ciphertext) -> Decapsulate(Key, Ciphertext) end}.

increment(Cell) -> lawspec_beam_handler:call(Cell, fun(N) -> {ok, N + 1} end).
