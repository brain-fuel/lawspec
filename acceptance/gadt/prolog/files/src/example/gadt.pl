/** <module> Native evaluation of typed expression trees and hidden carriers.
ref:DEC-prolog-janus
*/
:- module(lawspec_41aa2588b64b427a,
          [ls_evalNumber/2, ls_evalTruth/2, ls_evalPair/2, ls_fold/2, ls_describe/2]).

ls_evalNumber(value(Tag, Fields), R) :-
    ( Tag == 'example.gadt::type::Expr::Number' -> Fields = [R]
    ; Tag == 'example.gadt::type::Expr::Plus' ->
        Fields = [value(_, [Left, Right])],
        ls_evalNumber(Left, A), ls_evalNumber(Right, B), R is A+B
    ; throw(error(type_error(numeric_expression, Tag), _))
    ).

ls_evalTruth(value(Tag, Fields), R) :-
    ( Tag == 'example.gadt::type::Expr::Truth' -> Fields = [R]
    ; Tag == 'example.gadt::type::Expr::Same' ->
        Fields = [value(_, [Left, Right])],
        ls_evalNumber(Left, A), ls_evalNumber(Right, B),
        ( A =:= B -> R = true ; R = false )
    ; Tag == 'example.gadt::type::Expr::Negate' ->
        Fields = [Operand], ls_evalTruth(Operand, Value),
        ( Value == true -> R = false ; R = true )
    ; throw(error(type_error(truth_expression, Tag), _))
    ).

ls_evalPair(value('example.gadt::type::Expr::Both', [value(_, [First, Second])]),
            value('example.gadt::type::Pair::Pair', [A, B])) :-
    ls_evalNumber(First, A), ls_evalTruth(Second, B).

ls_fold(Expr, value('example.gadt::type::Expr::Number', [Number])) :-
    ls_evalNumber(Expr, Number).

ls_describe(value('example.gadt::type::Shown::Shown', [_, Witness]), Witness).
