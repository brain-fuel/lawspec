/** <module> Independent native adapters for the shared tables laws.
ref:DEC-prolog-janus
*/
:- module(example_tables, [ls_shippingCost/3, ls_label/2]).

ls_shippingCost(Count, Rate, R) :- R is Count*Rate+5*Count.
ls_label(Number, R) :- number_string(Number, Text), string_concat("parcel ", Text, R).
