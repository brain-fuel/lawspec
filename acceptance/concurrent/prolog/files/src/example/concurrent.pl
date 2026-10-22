/** <module> Native shared queue, set and map with per-instance Python locks.

Janus retains the native collections and locks. The checked Core histories
provide the independent queue/set/map semantics and linearizability oracle.
ref:DEC-prolog-janus
*/
:- module(lawspec_3975de17dcbd2ef5, [ls_newQueue/2, ls_offer/3, ls_poll/2, ls_queueSize/2,
    ls_newTags/2, ls_tag/3, ls_untag/3, ls_tagged/3,
    ls_newCache/2, ls_store/4, ls_fetch/3, ls_evict/3]).
:- use_module(library(janus)).
:- dynamic registry/1.
:- initialization(init_registry).

init_registry :-
    py_call(builtins:dict(lock=eval(threading:'RLock'()), entries=eval(builtins:dict())),
            Registry, [py_object(true)]), assertz(registry(Registry)).

ls_newQueue(_, value('example.concurrent::type::WorkQueue::WorkQueue', [Id])) :- new(queue, Id).
ls_newTags(_, value('example.concurrent::type::Tags::Tags', [Id])) :- new(tags, Id).
ls_newCache(_, value('example.concurrent::type::Cache::Cache', [Id])) :- new(cache, Id).
new(Kind, Id) :- flag(lawspec_fixture_collection_ids, Id, Id+1), get_state(Kind, Id, _).

get_state(Kind, Id, State) :-
    registry(Registry), py_call(Registry:get(lock), Lock),
    py_call(Registry:get(entries), Entries, [py_object(true)]),
    setup_call_cleanup(py_call(Lock:acquire()), ensure_state(Entries, Kind-Id, Kind, State),
                       py_call(Lock:release())).
ensure_state(Entries, Key, Kind, State) :-
    py_call(Entries:get(Key), Existing, [py_object(true)]),
    ( Existing == @(none) ->
        empty(Kind, Items),
        py_call(builtins:dict(lock=eval(threading:'RLock'()), items=Items), State, [py_object(true)]),
        py_call(Entries:'__setitem__'(Key, State))
    ; State = Existing
    ).
empty(queue, Items) :- py_call(collections:deque(), Items, [py_object(true)]).
empty(tags, Items) :- py_call(builtins:set(), Items, [py_object(true)]).
empty(cache, Items) :- py_call(builtins:dict(), Items, [py_object(true)]).

ls_offer(Value, Item, R) :- with_items(Value, queue, offer(Item), R).
ls_poll(Value, R) :- with_items(Value, queue, poll, R).
ls_queueSize(Value, R) :- with_items(Value, queue, size, R).
ls_tag(Value, Item, R) :- with_items(Value, tags, tag(Item), R).
ls_untag(Value, Item, R) :- with_items(Value, tags, untag(Item), R).
ls_tagged(Value, Item, R) :- with_items(Value, tags, tagged(Item), R).
ls_store(Value, Key, Entry, R) :- with_items(Value, cache, store(Key, Entry), R).
ls_fetch(Value, Key, R) :- with_items(Value, cache, fetch(Key), R).
ls_evict(Value, Key, R) :- with_items(Value, cache, evict(Key), R).

with_items(value(_, [Id]), Kind, Operation, R) :-
    get_state(Kind, Id, State), py_call(State:get(lock), Lock),
    py_call(State:get(items), Items, [py_object(true)]),
    setup_call_cleanup(py_call(Lock:acquire()), operate(Operation, Items, R), py_call(Lock:release())).

operate(offer(Item), Items, absence('Unit')) :- py_call(Items:append(Item)).
operate(poll, Items, R) :-
    py_call(builtins:len(Items), Count),
    ( Count =:= 0 -> R = value('Maybe::Absent', [])
    ; py_call(Items:popleft(), Value), R = value('Maybe::Present', [Value])
    ).
operate(size, Items, Count) :- py_call(builtins:len(Items), Count).
operate(tag(Item), Items, R) :-
    py_call(Items:'__contains__'(Item), Present),
    ( Present == @(true) -> R = false ; R = true ), py_call(Items:add(Item)).
operate(untag(Item), Items, R) :-
    py_call(Items:'__contains__'(Item), Present),
    ( Present == @(true) -> R = true ; R = false ), py_call(Items:discard(Item)).
operate(tagged(Item), Items, R) :-
    py_call(Items:'__contains__'(Item), Present),
    ( Present == @(true) -> R = true ; R = false ).
operate(store(Key, Entry), Items, R) :-
    py_call(Items:get(Key), Previous), py_call(Items:'__setitem__'(Key, Entry)), maybe(Previous, R).
operate(fetch(Key), Items, R) :- py_call(Items:get(Key), Entry), maybe(Entry, R).
operate(evict(Key), Items, R) :- py_call(Items:pop(Key, @(none)), Entry), maybe(Entry, R).
maybe(Value, R) :- ( Value == @(none) -> R = value('Maybe::Absent', []) ; R = value('Maybe::Present', [Value]) ).
