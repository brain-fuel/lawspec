// User-owned LawSpec adapter. Implement these methods.
namespace Lessons;

using System;
using System.Collections.Generic;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.FSharp.Core;
using Microsoft.FSharp.Collections;
using LawSpec.CSharp;

public static class Codec
{
    /// <summary>(Int32 -> Text)</summary>
    public static string FormatQuantity(int value0)
    {
        throw new NotImplementedException("not implemented: lessons.codec::formatQuantity");
    }

    /// <summary>(Text -> Int32)</summary>
    public static int ParseQuantity(string value0)
    {
        throw new NotImplementedException("not implemented: lessons.codec::parseQuantity");
    }
}
