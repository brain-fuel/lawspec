/** <module> The checked existential carrier remains visible to native code.
ref:DEC-prolog-janus
*/
:- module(lawspec_41aa2588b64b427a, [ls_describe/2]).

ls_describe(value('example.gadt::type::Shown::Shown', [_, Witness]), Witness).
