package domain

import lawspec.data.Parcel
import lawspec.data.Chain
import lawspec.data.Positive
import lawspec.runtime.LawSpecRuntime.Just
import lawspec.runtime.LawSpecRuntime.Nothing
import lawspec.runtime.LawSpecRuntime.Maybe

object CodecHooks {
    fun <A, B> to_parcel(value: Parcel<A>, convert: (A) -> B): CodecDomain.Parcel<B> =
        CodecDomain.Parcel(convert((value as Parcel.ParcelCase<A>).item))

    fun <A, B> from_parcel(value: CodecDomain.Parcel<B>, convert: (B) -> A): Parcel<A> =
        Parcel.ParcelCase(convert(value.unpack()))

    fun <A, B> to_chain(value: Chain<A>, convert: (A) -> B): CodecDomain.FlatChain<B> {
        var current = value
        val items = mutableListOf<B>()
        while (current is Chain.MoreCase<A>) {
            items.add(convert(current.item))
            val tail = current.tail
            if (tail is Nothing<Chain<A>>) return CodecDomain.FlatChain(items, false)
            current = (tail as Just<Chain<A>>).value()
        }
        return CodecDomain.FlatChain(items, true)
    }

    fun <A, B> from_chain(value: CodecDomain.FlatChain<B>, convert: (B) -> A): Chain<A> {
        var tail: Maybe<Chain<A>> = if (value.ended()) Just(Chain.StopCase()) else Nothing()
        for (item in value.items().asReversed()) tail = Just(Chain.MoreCase(convert(item), tail))
        require(tail !is Nothing<Chain<A>>) { "empty chain without Stop has no logical value" }
        return (tail as Just<Chain<A>>).value()
    }

    fun to_positive(value: Positive): CodecDomain.Positive =
        CodecDomain.Positive((value as Positive.PositiveCase).value)

    fun from_positive(value: CodecDomain.Positive): Positive =
        Positive.PositiveCase(value.unpack())
}
