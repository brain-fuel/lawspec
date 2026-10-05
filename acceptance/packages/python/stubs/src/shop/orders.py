# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: shop.orders::type::Currency
# LawSpec result: shop.domain::type::Currency
def settlement(value0: data.ShopOrdersCurrency) -> data.ShopDomainCurrency:
    raise NotImplementedError("settlement")


# LawSpec argument 0: shop.orders::type::Line
# LawSpec result: shop.domain::type::Money
def lineTotal(value0: data.Line) -> data.Money:
    raise NotImplementedError("lineTotal")


# LawSpec argument 0: Int64
# LawSpec argument 1: Int64
# LawSpec result: Int64
def cheaper(value0: int, value1: int) -> int:
    raise NotImplementedError("cheaper")


# LawSpec argument 0: Int64
# LawSpec result: Int64
def roundDown(value0: int) -> int:
    raise NotImplementedError("roundDown")


# LawSpec argument 0: Int64
# LawSpec result: shop.tax.v2x0x0.rates::type::Band
def classify(value0: int) -> data.ShopTaxV2x0x0RatesBand:
    raise NotImplementedError("classify")
