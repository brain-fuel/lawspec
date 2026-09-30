# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: shop.domain::type::Currency
# LawSpec argument 1: shop.domain::type::Money
# LawSpec result: shop.domain::type::Money
def convert(value0: data.ShopDomainCurrency, value1: data.Money) -> data.Money:
    raise NotImplementedError("convert")
