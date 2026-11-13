# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument currency_1: shop.domain::type::Currency
# LawSpec argument money_1: shop.domain::type::Money
# LawSpec result: shop.domain::type::Money
def convert(
    currency_1: data.ShopDomainCurrency,
    money_1: data.Money,
) -> data.Money:
    raise NotImplementedError("convert")
