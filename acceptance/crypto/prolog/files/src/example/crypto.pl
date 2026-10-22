/** <module> Cryptography through explicit Hash and Aead capability arguments.

Known-answer vectors validate the underlying provider independently. These
application adapters must forward each operation and preserve its typed data.
*/
:- module(lawspec_222d224c5b274737, [ls_fingerprint/3, ls_roundTrip/3]).

ls_fingerprint(Hash, Input, bytes(Prefix)) :-
    lawspec_prolog:operation(Hash, sha3, [Input], value(_, [bytes(Digest)])),
    length(Prefix, 8),
    append(Prefix, _, Digest).

ls_roundTrip(Aead, Input, Result) :-
    lawspec_prolog:operation(Aead, aeadKey, [], Key),
    lawspec_prolog:operation(Aead, seal, [Key, Input, bytes([114])], Sealed),
    lawspec_prolog:operation(Aead, unseal, [Key, Sealed, bytes([114])], Opened),
    ( Opened == value('Maybe::Present', [Input]) -> Result=true ; Result=false ).
