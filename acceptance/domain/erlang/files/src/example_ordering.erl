%% ref:DEC-acceptance-with-mutants
-module(example_ordering).
-export([first_line/1, validate_order/1, price_order/1]).
first_line({non_empty_list, Values}) -> hd(Values).
validate_order({unvalidated_order, <<>>, _}) -> {left, order_error_invalid_order_id};
validate_order({unvalidated_order, _, Quantity}) when Quantity < 1; Quantity > 1000 -> {left, order_error_invalid_quantity};
validate_order({unvalidated_order, Id, Quantity}) -> {right, {validated_order, {order_id, Id}, {unit_quantity, Quantity}}}.
price_order({validated_order, Id, {unit_quantity, Quantity} = Wrapped}) ->
    Total = Quantity * 25,
    case Total > 20000 of
        true -> {left, order_error_price_too_high};
        false -> {right, {priced_order, Id, Wrapped, Total}}
    end.
