/** <module> Per-instance native handler state and typed refund failures.
ref:DEC-prolog-janus
*/
:- module(lawspec_99c20d706948246d,
          [ls_refund/3, handler_LogHandler_new/1, handler_LogHandler_note/3,
           handler_StoreInt32Handler_new/1, handler_StoreInt32Handler_load/2,
           handler_StoreInt32Handler_save/3, handler_StoreTextHandler_new/1,
           handler_StoreTextHandler_load/2, handler_StoreTextHandler_save/3,
           handler_MeterHandler_new/1, handler_MeterHandler_reading/2]).
:- use_module(library(janus)).

ls_refund(Gateway, Amount, R) :-
    ( Amount > 100000 -> throw(lawspec_failure(value('example.abilities::type::PaymentError::TooLarge', [])))
    ; lawspec_prolog:operation(Gateway, capture, [Amount], value(_, [R]))
    ).

handler_LogHandler_new(log(State)) :-
    py_call(builtins:dict(lines=eval(builtins:list())), State, [py_object(true)]).
handler_LogHandler_note(log(State), Text, absence('Unit')) :-
    py_call(State:get(lines), Lines, [py_object(true)]), py_call(Lines:append(Text)).

handler_StoreInt32Handler_new(store(State)) :-
    py_call(builtins:dict(value=0), State, [py_object(true)]).
handler_StoreInt32Handler_load(store(State), R) :- py_call(State:get(value), R).
handler_StoreInt32Handler_save(store(State), Value, absence('Unit')) :-
    py_call(State:'__setitem__'(value, Value)).

handler_StoreTextHandler_new(store(State)) :-
    py_call(builtins:dict(value=""), State, [py_object(true)]).
handler_StoreTextHandler_load(store(State), R) :-
    py_call(State:get(value), R, [py_string_as(string)]).
handler_StoreTextHandler_save(store(State), Value, absence('Unit')) :-
    py_call(State:'__setitem__'(value, Value)).

handler_MeterHandler_new(meter).
handler_MeterHandler_reading(meter, 3).
