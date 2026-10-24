/** <module> The checked existential carrier remains visible to native code.
ref:DEC-prolog-janus
*/
:- module(example_gadt, [ls_describe/2]).

ls_describe(value('example.gadt::type::Shown::Shown', [_, Witness]), Witness).
