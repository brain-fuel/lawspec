/** <module> Native values returned by asynchronous and synchronous adapters.
ref:DEC-prolog-janus
*/
:- module(lawspec_3d60016e91d95694, [ls_price/2, ls_stock/2, ls_quote/2]).

ls_price(Sku, Price) :- price(Sku, Price).
ls_quote(Sku, Price) :- price(Sku, Price).
ls_stock(Sku, Count) :- string_length(Sku, Count).
price(Sku, Price) :-
    ( Sku == "free" -> Price = 0 ; string_length(Sku, Length), Price is Length mod 100 ).
