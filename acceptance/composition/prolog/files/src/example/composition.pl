/** <module> Native Logs, Reader and Writer share each case's resource.
ref:DEC-prolog-janus
*/
:- module(lawspec_dab7bcf1632b0da3, [ls_openStore/2, ls_closeStore/2,
    handler_LogsHandler_new/2, handler_LogsHandler_create/3, handler_LogsHandler_append/4,
    handler_ReaderHandler_new/2, handler_ReaderHandler_size/3,
    handler_WriterHandler_new/2, handler_WriterHandler_write/4,
    handler_WriterHandler_lastOffset/2]).
:- use_module(library(janus)).

ls_openStore(_, opaque(Store)) :-
    py_call(builtins:dict(logs=eval(builtins:dict()), open= @(true)), Store, [py_object(true)]).
ls_closeStore(Handle, absence('Unit')) :-
    lawspec_prolog:native_handle(Handle, Store), py_call(Store:'__setitem__'(open, @(false))).

handler_LogsHandler_new(Handle, logs(Store)) :- lawspec_prolog:native_handle(Handle, Store).
handler_LogsHandler_create(logs(Store), Name, absence('Unit')) :-
    py_call(Store:get(logs), Logs, [py_object(true)]), py_call(Logs:'__setitem__'(Name, [])).
handler_LogsHandler_append(logs(Store), Name, Record, Offset) :-
    py_call(Store:get(logs), Logs, [py_object(true)]),
    py_call(Logs:get(Name), Records, [py_object(true)]),
    ( Records == @(none) ->
        throw(lawspec_failure(value('example.composition::type::Problem::UnknownLog', [])))
    ; Record == "" ->
        throw(lawspec_failure(value('example.composition::type::Problem::EmptyRecord', [])))
    ; py_call(Records:append(Record)), py_call(builtins:len(Records), Count), Offset is Count-1
    ).

handler_ReaderHandler_new(Handle, reader(Store)) :- lawspec_prolog:native_handle(Handle, Store).
handler_ReaderHandler_size(reader(Store), Name, Result) :-
    py_call(Store:get(logs), Logs, [py_object(true)]),
    py_call(Logs:get(Name), Records, [py_object(true)]),
    ( Records == @(none) -> Result = value('Maybe::Nothing', [])
    ; py_call(builtins:len(Records), Count), Result = value('Maybe::Just', [Count])
    ).

handler_WriterHandler_new(Handle, writer(Store, Last)) :-
    lawspec_prolog:native_handle(Handle, Store),
    py_call(builtins:dict(offset= @(none)), Last, [py_object(true)]).
handler_WriterHandler_write(writer(Store, Last), Name, Record, Written) :-
    py_call(Store:get(logs), Logs, [py_object(true)]),
    py_call(Logs:get(Name), Records, [py_object(true)]),
    ( Records == @(none) -> Written = false
    ; Record == "" -> Written = false
    ; py_call(Records:append(Record)), py_call(builtins:len(Records), Count),
      Offset is Count-1, py_call(Last:'__setitem__'(offset, Offset)), Written = true
    ).
handler_WriterHandler_lastOffset(writer(_, Last), Result) :-
    py_call(Last:get(offset), Offset),
    ( Offset == @(none) -> Result = value('Maybe::Nothing', [])
    ; Result = value('Maybe::Just', [Offset])
    ).
