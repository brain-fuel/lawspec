/** <module> Functional Prolog calls over the checked Python value domain.

Janus supplies the foreign interface; SWI's determinism guard supplies the
functional-call check. This module is execution infrastructure, not a solver
or proof checker. Values have explicit tags where Prolog's native domain would
erase a distinction (presence, IEEE bits, Decimal and constructor identity).
ref:DEC-prolog-janus
*/
:- module(lawspec_prolog, [invoke/4, invoke_bound/5, new_handler/4, new_handler_bound/5, strategy/4, operation/4, native_handle/2, new_context/1, model/3, model/4, run_slots/1, encode/2, decode/2]).
:- use_module(library(error)).
:- use_module(library(janus)).

% Python supplies names as data, never as interpolated goal text. An adapter
% receives its inputs followed by one output, and must succeed deterministically.
invoke(Module, Predicate, Packed, Outcome) :-
    must_be(atom, Module),
    must_be(atom, Predicate),
    must_be(list, Packed),
    require_guard(Predicate),
    maplist(decode, Packed, Arguments),
    append(Arguments, [Result], All),
    compound_name_arguments(Goal, Predicate, All),
    catch(( '$'(call(Module:Goal)),
            require_guard(Predicate),
            must_be(acyclic, Result),
            must_be(ground, Result),
            encode(Result, Value),
            Outcome = [ok, Value]
          ), Error, exceptional(Error, Outcome)).

require_guard(Predicate) :-
    ( current_prolog_flag(determinism_error, error) -> true
    ; throw(error(permission_error(call, determinism_guard, Predicate), _))
    ).

% Native representation metadata comes from resolved Core bindings. Dict tags
% and functors are qualified identities; no configuration contains goal text.
invoke_bound(Module, Predicate, Packed, Bindings, Outcome) :-
    must_be(atom, Module), must_be(atom, Predicate), must_be(list, Packed),
    require_guard(Predicate),
    catch(( maplist(decode_bound(Bindings), Packed, Arguments),
            append(Arguments, [Result], All),
            compound_name_arguments(Goal, Predicate, All),
            '$'(call(Module:Goal)), require_guard(Predicate),
            must_be(acyclic, Result), must_be(ground, Result),
            encode_bound(Bindings, Result, Value), Outcome = [ok, Value]
          ), Error, exceptional_bound(Bindings, Error, Outcome)).

new_handler_bound(Module, Factory, Packed, Bindings, prolog(Instance)) :-
    must_be(atom, Module), must_be(atom, Factory), require_guard(Factory),
    maplist(decode_bound(Bindings), Packed, Resources),
    append(Resources, [Instance], Arguments), compound_name_arguments(Goal, Factory, Arguments),
    '$'(call(Module:Goal)), require_guard(Factory),
    must_be(acyclic, Instance), must_be(ground, Instance).

decode_bound(Bindings, Packed, Native) :-
    decode(Packed, Logical), bound_native(Bindings, Logical, Native).
bound_native(Bindings, value(Tag, Fields), Native) :- !,
    Bindings = [Constructors, _, _],
    ( memberchk([Tag, Name, Style, Names, Layout], Constructors) ->
        layout_flatten(Layout, Fields, Indexed), keysort(Indexed, Ordered),
        pairs_values(Ordered, Leaves), maplist(bound_native(Bindings), Leaves, Arguments),
        native_construct(Style, Name, Names, Arguments, Native)
    ; maplist(bound_native(Bindings), Fields, Values), Native = value(Tag, Values)
    ).
bound_native(Bindings, handler(Object), native_handler(Object, Bindings)) :- !.
bound_native(Bindings, presence(Kind, present(Value)), presence(Kind, present(Native))) :- !,
    bound_native(Bindings, Value, Native).
bound_native(Bindings, Values, Natives) :- is_list(Values), !,
    maplist(bound_native(Bindings), Values, Natives).
bound_native(_, Value, Value).

native_construct(record, Name, Names, Values, Native) :- !,
    pairs_keys_values(Pairs, Names, Values), dict_create(Native, Name, Pairs).
native_construct(variant, Name, _, Values, Native) :- !,
    compound_name_arguments(Native, Name, Values).
native_construct(unit, Name, [], [], Name).

layout_flatten(Layout, Fields, Leaves) :-
    same_length(Layout, Fields), maplist(layout_leaves, Layout, Fields, Nested), append(Nested, Leaves).
layout_leaves([leaf, Index], Value, [Index-Value]).
layout_leaves([record, Tag, Children], value(Tag, Fields), Leaves) :-
    layout_flatten(Children, Fields, Leaves).
encode_bound(Bindings, Native, Packed) :-
    ( native_shape(Native, Name), Bindings = [Constructors, _, _],
      memberchk([Tag, Name, Style, Names, Layout], Constructors) ->
        native_fields(Style, Name, Names, Native, Arguments),
        maplist(encode_bound(Bindings), Arguments, Encoded),
        maplist(layout_packed(Encoded), Layout, Fields), Packed = [value, Tag, Fields]
    ; native_shape(Native, HandleName), Bindings = [_, Handles, _], memberchk([_, HandleName], Handles) ->
        Packed = [native_handle, HandleName, prolog(Native)]
    ; Native = value(Tag, Fields) ->
        Bindings = [Constructors, _, _],
        ( memberchk([Tag, Name, _, _, _], Constructors) ->
            throw(error(type_error(native_representation(Name), Native), _))
        ; maplist(encode_bound(Bindings), Fields, Values), Packed = [value, Tag, Values]
        )
    ; is_list(Native) -> maplist(encode_bound(Bindings), Native, Values), Packed = [list, Values]
    ; Native = presence(Kind, present(Value)) ->
        encode_bound(Bindings, Value, Child), Packed = [presence, Kind, @(true), Child]
    ; encode(Native, Packed)
    ).

layout_packed(Arguments, [leaf, Index], Value) :- nth0(Index, Arguments, Value).
layout_packed(Arguments, [record, Tag, Children], [value, Tag, Fields]) :-
    maplist(layout_packed(Arguments), Children, Fields).

native_shape(Value, Name) :-
    ( is_dict(Value, Name) -> true
    ; compound(Value), \+ is_dict(Value) -> compound_name_arity(Value, Name, _)
    ; atom(Value) -> Name = Value
    ).
native_fields(record, Name, Names, Value, Fields) :-
    ( is_dict(Value, Name) -> maplist(required_field(Value), Names, Fields)
    ; throw(error(type_error(native_record(Name), Value), _))
    ).
native_fields(variant, Name, Names, Value, Fields) :-
    ( compound(Value), \+ is_dict(Value), compound_name_arguments(Value, Name, Fields),
      same_length(Names, Fields) -> true
    ; throw(error(type_error(native_variant(Name), Value), _))
    ).
native_fields(unit, Name, [], Value, []) :-
    ( Value == Name -> true ; throw(error(type_error(native_unit(Name), Value), _)) ).
required_field(Value, Name, Field) :-
    ( get_dict(Name, Value, Field) -> true
    ; throw(error(existence_error(native_field, Name), _))
    ).

exceptional_bound([_, _, Failures], Error, Outcome) :-
    ( mapped_exception(Error, Name, Message), memberchk([Name, Tag, Payload], Failures) ->
        failure_fields(Payload, Message, Fields), encode(value(Tag, Fields), Packed), Outcome = [failure, Packed]
    ; exceptional(Error, Outcome)
    ).
mapped_exception(error(Formal, _), Name, Message) :- !, exception_shape(Formal, Name, Message).
mapped_exception(Error, Name, Message) :- exception_shape(Error, Name, Message).
exception_shape(Error, Name, Message) :-
    ( atom(Error) -> Name = Error, Message = ""
    ; compound(Error), \+ is_dict(Error), compound_name_arguments(Error, Name, Arguments),
      ( Arguments = [] -> Message = ""
      ; Arguments = [Message], string(Message)
      )
    ).
failure_fields([], _, []).
failure_fields([message], Message, [Message]).
failure_fields([record, Tag, Child], Message, [value(Tag, Fields)]) :- failure_fields(Child, Message, Fields).

new_handler(Module, Factory, Packed, prolog(Instance)) :-
    must_be(atom, Module),
    must_be(atom, Factory),
    require_guard(Factory),
    maplist(decode, Packed, Resources),
    append(Resources, [Instance], Arguments),
    compound_name_arguments(Goal, Factory, Arguments),
    '$'(call(Module:Goal)),
    require_guard(Factory),
    must_be(acyclic, Instance),
    must_be(ground, Instance).

% Strategies stay Python objects: Hypothesis owns generation and shrinking.
% A factory receives one child strategy per type parameter, then its output.
strategy(Module, Factory, Children, Strategy) :-
    must_be(atom, Module),
    must_be(atom, Factory),
    must_be(list, Children),
    maplist(py_is_object, Children),
    require_guard(Factory),
    append(Children, [Strategy], Arguments),
    compound_name_arguments(Goal, Factory, Arguments),
    '$'(call(Module:Goal)),
    require_guard(Factory),
    py_is_object(Strategy).

exceptional(lawspec_failure(Value), [failure, Packed]) :-
    !,
    must_be(acyclic, Value),
    must_be(ground, Value),
    encode(Value, Packed).
exceptional(lawspec_incomplete(Reason), [incomplete, Reason]) :-
    !,
    must_be(string, Reason).
exceptional(lawspec_ability_failure(Ability, Value), [ability_failure, Ability, Packed]) :-
    !,
    must_be(atom, Ability),
    must_be(acyclic, Value),
    must_be(ground, Value),
    encode(Value, Packed).
exceptional(Error, _) :- throw(Error).

operation(native_handler(Object, Bindings), Name, Arguments, Result) :- !,
    must_be(atom, Name), must_be(acyclic, Arguments), must_be(ground, Arguments), must_be(list, Arguments),
    maplist(encode_bound(Bindings), Arguments, Packed), py_call(Object:invoke(Name, Packed), Outcome),
    ( Outcome = [ok, Value] -> decode_bound(Bindings, Value, Result)
    ; operation_result(Outcome, Result)
    ).
operation(handler(Object), Name, Arguments, Result) :-
    must_be(atom, Name),
    must_be(acyclic, Arguments),
    must_be(ground, Arguments),
    must_be(list, Arguments),
    maplist(encode, Arguments, Packed),
    py_call(Object:invoke(Name, Packed), Outcome),
    operation_result(Outcome, Result).

operation_result([ok, Packed], Result) :- !, decode(Packed, Result).
operation_result([ability_failure, Ability, Packed], _) :- !,
    decode(Packed, Value),
    throw(lawspec_ability_failure(Ability, Value)).
operation_result([incomplete, Codes], _) :- !,
    string_codes(Reason, Codes),
    throw(lawspec_incomplete(Reason)).
operation_result(Outcome, _) :- throw(error(type_error(lawspec_operation_result, Outcome), _)).

% The generated registry names checked definitions by Core identity. Arguments
% and results cross the same schema boundary as native adapter calls.
model(Identity, Arguments, Result) :-
    new_context(Context),
    model(Context, Identity, Arguments, Result).

new_context(context(Object)) :- py_call(builtins:dict(), Object, [py_object(true)]).

model(context(Context), Identity, Arguments, Result) :-
    must_be(atom, Identity),
    must_be(acyclic, Arguments),
    must_be(ground, Arguments),
    must_be(list, Arguments),
    maplist(encode, Arguments, Packed),
    py_call(lawspec_prolog_models:invoke(Identity, Packed, Context), Outcome),
    operation_result(Outcome, Result).

run_slots(Pairs) :-
    maplist(test_selector, Pairs, Tests),
    run_tests(Tests).

test_selector(Unit-Name, Unit:Name).

% Native implementations can call the original object's API while returning
% the original opaque term when they need to preserve handle identity.
native_handle(opaque(Holder), Native) :-
    py_call(lawspec_prolog:native_handle(Holder), Native, [py_object(true)]).

% These codecs are deliberately structural. The existing Core schema validates
% types, machine widths, constructor refinements and indices at the boundary.
decode([integer, N], N) :- !, must_be(integer, N).
decode([bool, B], Value) :- !,
    ( B == @(true) -> Value = true
    ; B == @(false) -> Value = false
    ; throw(error(type_error(bool, B), _)) ).
decode([text, Codes], Text) :- !, string_codes(Text, Codes).
decode([float, Bits], ieee(Bits)) :- !, must_be(nonneg, Bits).
decode([complex, Real, Imaginary], complex(ieee(Real), ieee(Imaginary))) :- !.
decode([decimal, Sign, Digits, Exponent], decimal(Sign, Digits, Exponent)) :- !.
decode([rational, N, D], rational(N, D)) :- !.
decode([bytes, Bytes], bytes(Bytes)) :- !.
decode([raw, Kind, Units], raw(Kind, Units)) :- !.
decode([absence, Kind], absence(Kind)) :- !.
decode([symbol, Object], symbol(Object)) :- !.
decode([opaque, Object], opaque(Object)) :- !.
decode([handler, Object], handler(Object)) :- !.
decode([prolog_state, Instance], Instance) :- !.
decode([value, Tag, Fields], value(Tag, Values)) :- !,
    maplist(decode, Fields, Values).
decode([list, Items], Values) :- !, maplist(decode, Items, Values).
decode([presence, Kind, @(false)], presence(Kind, absent)) :- !.
decode([presence, Kind, @(true), Item], presence(Kind, present(Value))) :- !,
    decode(Item, Value).
decode(Packed, _) :- throw(error(type_error(lawspec_value, Packed), _)).

encode(Value, Packed) :-
    ( integer(Value) -> Packed = [integer, Value]
    ; string(Value) -> string_codes(Value, Codes), Packed = [text, Codes]
    ; Value == true -> Packed = [bool, @(true)]
    ; Value == false -> Packed = [bool, @(false)]
    ; is_list(Value) -> maplist(encode, Value, Items), Packed = [list, Items]
    ; encoded(Value, Packed) -> true
    ; throw(error(type_error(lawspec_value, Value), _))
    ).

encoded(ieee(Bits), [float, Bits]) :- must_be(nonneg, Bits).
encoded(complex(ieee(Real), ieee(Imaginary)), [complex, Real, Imaginary]).
encoded(decimal(Sign, Digits, Exponent), [decimal, Sign, Digits, Exponent]).
encoded(rational(N, D), [rational, N, D]).
encoded(bytes(Bytes), [bytes, Bytes]).
encoded(raw(Kind, Units), [raw, Kind, Units]).
encoded(absence(Kind), [absence, Kind]).
encoded(symbol(Object), [symbol, Object]) :- py_is_object(Object).
encoded(opaque(Object), [opaque, Object]) :- py_is_object(Object).
encoded(handler(Object), [handler, Object]) :- py_is_object(Object).
encoded(value(Tag, Fields), [value, Tag, Values]) :-
    must_be(atom, Tag), must_be(list, Fields), maplist(encode, Fields, Values).
encoded(presence(Kind, absent), [presence, Kind, @(false)]).
encoded(presence(Kind, present(Value)), [presence, Kind, @(true), Packed]) :-
    encode(Value, Packed).
