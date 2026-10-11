// User-owned LawSpec adapter. Implement these methods.
namespace Lessons;

using System;
using System.Collections.Generic;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.FSharp.Core;
using Microsoft.FSharp.Collections;
using LawSpec.CSharp;

public static class Checkout
{
    /// <summary>(lessons.checkout::type::RawOrder -> Either (lessons.checkout::type::OrderProblem) (lessons.checkout::type::ValidOrder))</summary>
    public static LawSpec.Either<LawSpec.Data.OrderProblem, LawSpec.Data.ValidOrder> Validate(LawSpec.Data.RawOrder value0)
    {
        throw new NotImplementedException("not implemented: lessons.checkout::validate");
    }

    /// <summary>(lessons.checkout::type::ValidOrder -> lessons.checkout::type::Receipt)</summary>
    public static LawSpec.Data.Receipt Charge(LawSpec.Data.ValidOrder value0)
    {
        throw new NotImplementedException("not implemented: lessons.checkout::charge");
    }
}
