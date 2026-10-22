/** <module> Native currency conversion preserves the imported checked money.
ref:DEC-prolog-janus
*/
:- module(lawspec_869e0abdab4754ee, [ls_convert/3]).

ls_convert(Currency, value(Tag, [_, Cents]), value(Tag, [Currency, Cents])).
