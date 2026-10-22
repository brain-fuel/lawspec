/** <module> Native strategy factory with Hypothesis's ordinary shrinker.

Janus retains child and result strategies as Python objects. The generated
schema validates every generated native value and every candidate shrink.
*/
:- module('domain.payment_generators', [prices/1]).
:- use_module(library(janus)).

prices(Strategy) :-
    py_call('hypothesis.strategies':integers(100, 200), Cents, [py_object(true)]),
    py_call('hypothesis.strategies':just(-2), Exponent, [py_object(true)]),
    py_call(lawspec_runtime:make_decimal, Decimal, [py_object(true)]),
    py_call('hypothesis.strategies':builds(Decimal, Cents, Exponent), Amounts, [py_object(true)]),
    py_call(lawspec_data:'CurrencyEUR'(), Euro, [py_object(true)]),
    py_call('hypothesis.strategies':just(Euro), Currencies, [py_object(true)]),
    py_call(lawspec_data:'Money', Money, [py_object(true)]),
    py_call('hypothesis.strategies':builds(Money, Amounts, Currencies), Strategy, [py_object(true)]).
