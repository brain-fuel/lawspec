/** <module> Native clients use the generated distributed APIs and real transports.

Wire vectors and handshake vectors exercise the existing host runtime. Actor
state transitions and protocol peers are native Prolog implementations.
ref:DEC-prolog-janus
*/
:- module(lawspec_51badf03d520690b, [ls_encoded/5, ls_roundTrips/5,
    ls_openTally/2, ls_add/3, ls_remoteShifted/2, ls_remoteAdds/2,
    ls_remoteDoubling/2, ls_remoteLedger/2, ls_remoteHandoff/2,
    ls_remoteHandoffOnward/2, ls_sealedOnTheWire/2, ls_handshakeAgrees/2,
    double/2]).
:- use_module(library(janus)).

ls_encoded(Text, Seed, Size, Count, Values) :-
    py_call(lawspec_runtime:wire_encoded(Text, Seed, Size, Count), Values, [py_string_as(string)]).
ls_roundTrips(Text, Seed, Size, Count, Result) :-
    py_call(lawspec_runtime:wire_round_trips(Text, Seed, Size, Count), Truth), boolean(Truth, Result).
boolean(@(true), true).
boolean(@(false), false).

ls_openTally(_, value('example.distribution::type::Tally::Tally', [0])).
ls_add(value(_, [Before]), Amount,
    value('lawspec.collections::type::Pair::Pair',
        [After, value('example.distribution::type::Tally::Tally', [After])])) :- After is Before+Amount.

tcp(Node) :- py_call(lawspec_runtime:'Node'(eval(lawspec_runtime:'TcpTransport'())), Node).
http(Node) :- py_call(lawspec_runtime:'Node'(eval(lawspec_runtime:'HttpTransport'())), Node).
memory(Network, Name, Node) :- py_call(lawspec_runtime:'Node'(eval(Network:transport(Name))), Node).
close_node(Node) :- py_call(Node:close()).
address(Node, Suffix, Address) :-
    py_call(Node:address, Base, [py_string_as(string)]), string_concat(Base, Suffix, Address).

ls_remoteShifted(Number, Result) :-
    Seed is Number /\ 65535,
    py_call(lawspec_runtime:'MemoryNetwork'(seed=Seed, loss=0.2, duplicate=0.2), Network),
    setup_call_cleanup(memory(Network, here, Here),
        setup_call_cleanup(memory(Network, there, There),
            shifted(Here, There, Number, Result), close_node(There)), close_node(Here)).
shifted(Here, There, Number, Result) :-
    py_call(lawspec_remote:serve(There), _), py_call(There:address, Address),
    py_call(lawspec_remote:evaluate(Here, Address, 'example.distribution::shifted', Number), Result).

ls_remoteAdds(Amount, Total) :-
    setup_call_cleanup(tcp(Server),
        setup_call_cleanup(tcp(Client), remote_adds(Server, Client, Amount, Total), close_node(Client)), close_node(Server)).
remote_adds(Server, Client, Amount, Total) :-
    setup_call_cleanup(py_call(lawspec_actors:'TallyActor':start(), Actor),
        ( py_call(Actor:serve(Server, tally), Address),
          py_call(lawspec_actors:'TallyActor':connect(Client, Address), Tally),
          py_call(Tally:add(Amount), _),
          py_call(Tally:add(Amount), Total)
        ), py_call(Actor:stop())).

double(End, @(true)) :-
    py_call(End:receive(), Number-Reply), Twice is 2*Number, py_call(Reply:send(Twice), _).
spawn_double(End, Process) :-
    py_call(builtins:getattr(eval(builtins:'__import__'(janus_swi)), query_once), Query),
    py_call(builtins:dict('End'=End), Arguments, [py_object(true)]),
    py_call(functools:partial(Query, "lawspec_51badf03d520690b:double(End,_Result)", Arguments), Callback),
    py_call(lawspec_runtime:spawn(Callback), Process).
joined(Process) :-
    py_call(Process:join(), Answer, [py_object(true)]), py_call(Answer:get(truth), @(true)).
ask(End, Number, Result) :-
    py_call(End:send(Number), Reply), py_call(Reply:receive(), Result-_).

ls_remoteDoubling(Number, Result) :-
    setup_call_cleanup(http(Server),
        setup_call_cleanup(http(Client), remote_doubling(Server, Client, Number, Result), close_node(Client)), close_node(Server)).
remote_doubling(Server, Client, Number, Result) :-
    py_call(lawspec_sessions:'Doubling':listen(Server, doubling), First),
    address(Server, "/doubling", Address), py_call(lawspec_sessions:'Doubling':dial(Client, Address), Second),
    spawn_double(Second, Process), ask(First, Number, Result), joined(Process).

ls_remoteLedger(Number, Result) :-
    setup_call_cleanup(tcp(Here),
        setup_call_cleanup(tcp(There), remote_ledger(Here, There, Number, Result), close_node(There)), close_node(Here)).
remote_ledger(Here, There, Number, Result) :-
    py_call(lawspec_mailboxes:'LedgerMailbox':serve(There, ledger), Ledger),
    address(There, "/ledger", Address), py_call(lawspec_mailboxes:'LedgerMailbox':connect(Here, Address), Sender),
    py_call(Sender:send(Number)), py_call(Sender:send(Number)),
    py_call(Ledger:receive(5), A), py_call(Ledger:receive(5), B),
    py_call(Ledger:receive_within(eval(lawspec_runtime:timedelta(milliseconds=20))), Extra),
    ( Extra == @(none) -> Result is A+B ; Result = -1 ).

ls_remoteHandoff(Number, Result) :-
    setup_call_cleanup(tcp(Here),
        setup_call_cleanup(tcp(There), remote_handoff(Here, There, Number, Result), close_node(There)), close_node(Here)).
remote_handoff(Here, There, Number, Result) :-
    py_call(lawspec_sessions:'Doubling':open(), First-Second), spawn_double(Second, Process),
    py_call(lawspec_sessions:'Handoff':listen(Here, handoff), Giving),
    address(Here, "/handoff", Address), py_call(lawspec_sessions:'Handoff':dial(There, Address), Taking),
    py_call(Giving:send(First), _), py_call(Taking:receive(), End-_),
    ask(End, Number, Result), joined(Process).

ls_remoteHandoffOnward(Number, Result) :-
    Seed is Number /\ 65535,
    py_call(lawspec_runtime:'MemoryNetwork'(seed=Seed, loss=0.1, duplicate=0.1, delay=0.005), Network),
    setup_call_cleanup(memory(Network, a, A),
      setup_call_cleanup(memory(Network, b, B),
        setup_call_cleanup(memory(Network, c, C),
          setup_call_cleanup(memory(Network, d, D), onward(A, B, C, D, Number, Result), close_node(D)),
          close_node(C)), close_node(B)), close_node(A)).
onward(A, B, C, D, Number, Result) :-
    py_call(lawspec_sessions:'Answering':listen(A, answering), First),
    address(A, "/answering", Answering), py_call(lawspec_sessions:'Answering':dial(C, Answering), Peer),
    py_call(Peer:send(Number), Second),
    py_call(lawspec_sessions:'Passing':listen(A, 'to-b'), ToB),
    address(A, "/to-b", BAddress), py_call(lawspec_sessions:'Passing':dial(B, BAddress), AtB),
    py_call(ToB:send(First), _), py_call(AtB:receive(), Moved-_),
    py_call(lawspec_sessions:'Passing':listen(B, 'to-d'), ToD),
    address(B, "/to-d", DAddress), py_call(lawspec_sessions:'Passing':dial(D, DAddress), AtD),
    py_call(ToD:send(Moved), _), py_call(AtD:receive(), End-_),
    close_node(A), close_node(B),
    py_call(End:receive(), Value-Reply), Twice is 2*Value, py_call(Reply:send(Twice), _),
    py_call(Second:receive(), Result-_).

ls_sealedOnTheWire(Number, Result) :-
    py_call(builtins:bytes(eval(lawspec_remote:digest('example.distribution::shifted')), 'utf-8'),
        Digest, [py_object(true)]),
    sealed(false, Number, Digest, Secure), sealed(true, Number, Digest, Insecure),
    ( Secure == @(false), Insecure == @(true) -> Result = true ; Result = false ).
sealed(Insecure, Number, Digest, Seen) :-
    Seed is Number /\ 65535,
    py_call(lawspec_runtime:'MemoryNetwork'(seed=Seed, record= @(true)), Network),
    setup_call_cleanup(recorded_node(Insecure, Network, here, Here),
      setup_call_cleanup(recorded_node(Insecure, Network, there, There),
        ( shifted(Here, There, Number, Actual), Expected is Number+1000,
          ( Actual =:= Expected -> recorded_contains(Network, Digest, Seen) ; Seen = wrong_result )
        ), close_node(There)), close_node(Here)).
recorded_node(false, Network, Name, Node) :- memory(Network, Name, Node).
recorded_node(true, Network, Name, Node) :-
    py_call(lawspec_runtime:'Node'(eval(Network:insecure_transport_for_tests(Name))), Node).
recorded_contains(Network, Digest, Seen) :-
    py_call(Network:recorded, Frames, [py_object(true)]),
    py_call(operator:methodcaller('__contains__', Digest), Contains),
    py_call(builtins:any(eval(builtins:map(Contains, Frames))), Seen).

ls_handshakeAgrees(Text, Result) :-
    split_string(Text, " ", "", Fields), Goal =.. [handshake_vector|Fields],
    py_call(lawspec_network:Goal, Truth), boolean(Truth, Result).
