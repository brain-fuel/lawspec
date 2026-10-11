// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Shop;

using System;
using LawSpec.Data;

public static class Orders
{
    public static ShopDomainCurrency Settlement(ShopOrdersCurrency currency) =>
        currency.IsUsd ? ShopDomainCurrency.Usd : ShopDomainCurrency.Eur;

    public static Money LineTotal(Line line) =>
        new Money(line.Price.Currency, Math.Min(line.Price.Cents * line.Quantity.Value, 100000000L));

    public static long Cheaper(long a, long b) => Math.Min(a, b);

    public static long RoundDown(long cents) => cents - cents % 100L;

    // Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
    public static ShopTaxV2x0x0RatesBand Classify(long cents) =>
        cents <= 0L ? ShopTaxV2x0x0RatesBand.Zero
        : cents < 10000L ? ShopTaxV2x0x0RatesBand.Low
        : ShopTaxV2x0x0RatesBand.High;
}
