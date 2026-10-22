/** <module> Application-owned payments over canonical constructor terms.

The fee uses Prolog integer arithmetic, independently of the checked model's
decimal arithmetic. Aligning decimal exponents preserves every input digit.
*/
:- module('domain.payments', [apply_fee/2, restore/2, store/2]).

apply_fee(value(Tag, [decimal(Sign, Digits, Exponent), Currency]),
          value(Tag, [decimal(ResultSign, ResultDigits, Scale), Currency])) :-
    foldl(decimal_digit, Digits, 0, Magnitude),
    Coefficient is (1 - 2*Sign)*Magnitude,
    Scale is min(Exponent, -1),
    Sum is Coefficient*10**(Exponent-Scale) + 2*10**(-1-Scale),
    ( Sum < 0 -> ResultSign=1 ; ResultSign=0 ),
    Absolute is abs(Sum),
    number_codes(Absolute, Codes),
    maplist(digit_code, ResultDigits, Codes).

decimal_digit(Digit, Previous, Result) :- Result is Previous*10 + Digit.
digit_code(Digit, Code) :- Digit is Code - 0'0.

restore(Payment, Payment).
store(Payments, Payments).
