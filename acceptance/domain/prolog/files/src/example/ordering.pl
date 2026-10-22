/** <module> Independent native adapters for the shared domain laws.
ref:DEC-prolog-janus
*/
:- module(lawspec_95672250821d7d7e, [ls_firstLine/2, ls_validateOrder/2, ls_priceOrder/2]).

ls_firstLine(value(_, [[Head|_]]), Head).

ls_validateOrder(value('example.ordering::type::UnvalidatedOrder::UnvalidatedOrder', [Id, Quantity]), R) :-
    ( Id == "" -> R = value('Either::Left', [value('example.ordering::type::OrderError::InvalidOrderId', [])])
    ; Quantity < 1 -> R = value('Either::Left', [value('example.ordering::type::OrderError::InvalidQuantity', [])])
    ; Quantity > 1000 -> R = value('Either::Left', [value('example.ordering::type::OrderError::InvalidQuantity', [])])
    ; R = value('Either::Right', [value('example.ordering::type::ValidatedOrder::ValidatedOrder',
          [value('example.ordering::type::OrderId::OrderId', [Id]),
           value('example.ordering::type::UnitQuantity::UnitQuantity', [Quantity])])])
    ).

ls_priceOrder(value('example.ordering::type::ValidatedOrder::ValidatedOrder',
                  [Id, QuantityValue]), R) :-
    QuantityValue = value(_, [Quantity]),
    Total is Quantity*25,
    ( Total > 20000 -> R = value('Either::Left', [value('example.ordering::type::OrderError::PriceTooHigh', [])])
    ; R = value('Either::Right', [value('example.ordering::type::PricedOrder::PricedOrder',
                                     [Id, QuantityValue, Total])])
    ).
