# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument currency_1: shop.orders::type::Currency
# LawSpec result: shop.domain::type::Currency
def settlement(currency_1: data.ShopOrdersCurrency) -> data.ShopDomainCurrency:
    raise NotImplementedError("settlement")


# LawSpec argument line_1: shop.orders::type::Line
# LawSpec result: shop.domain::type::Money
def lineTotal(line_1: data.Line) -> data.Money:
    raise NotImplementedError("lineTotal")


# LawSpec argument int64_1: Int64
# LawSpec argument int64_2: Int64
# LawSpec result: Int64
def cheaper(int64_1: int, int64_2: int) -> int:
    raise NotImplementedError("cheaper")


# LawSpec argument int64_1: Int64
# LawSpec result: Int64
def roundDown(int64_1: int) -> int:
    raise NotImplementedError("roundDown")


# LawSpec argument int64_1: Int64
# LawSpec result: shop.tax.v2x0x0.rates::type::Band
def classify(int64_1: int) -> data.ShopTaxV2x0x0RatesBand:
    raise NotImplementedError("classify")
