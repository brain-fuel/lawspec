/** <module> Native currency conversion preserves the imported checked money.
ref:DEC-prolog-janus
*/
:- module(shop_domain, [ls_convert/3]).

ls_convert(Currency, value(Tag, [_, Cents]), value(Tag, [Currency, Cents])).
