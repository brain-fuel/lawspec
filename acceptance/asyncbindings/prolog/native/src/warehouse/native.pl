/** <module> Native price predicates and an atomically updated native shelf.
ref:DEC-prolog-janus
*/
:- module('warehouse.native', [price_of/2, quote_of/2, 'Shelf'/1, restock/3, count/2]).

price(Sku, Price) :-
    ( Sku == "free" -> Price = 0 ; string_length(Sku, Length), Price is Length mod 100 ).
price_of(Sku, Price) :- sleep(0), price(Sku, Price).
quote_of(Sku, Price) :- price(Sku, Price).

'Shelf'('warehouse.native.Shelf'(Id)) :-
    flag(lawspec_native_shelf_ids, Id, Id+1), shelf_key(Id, Key), flag(Key, _, 0).
restock('warehouse.native.Shelf'(Id), Amount, absence('Unit')) :-
    sleep(0), shelf_key(Id, Key), flag(Key, Before, Before+Amount).
count('warehouse.native.Shelf'(Id), Count) :- sleep(0), shelf_key(Id, Key), flag(Key, Count, Count).
shelf_key(Id, Key) :- atomic_list_concat([native_shelf_, Id], Key).
