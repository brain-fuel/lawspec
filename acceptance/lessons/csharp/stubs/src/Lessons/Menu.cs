// User-owned LawSpec adapter. Implement these methods.
namespace Lessons;

using System;
using System.Collections.Generic;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.FSharp.Core;
using Microsoft.FSharp.Collections;
using LawSpec.CSharp;

public static class Menu
{
  /// <summary>(lessons.menu::type::Item -> Int64)</summary>
  public static long PriceOf(LawSpec.Data.Item item1)
  {
    throw new NotImplementedException("not implemented: lessons.menu::priceOf");
  }

  /// <summary>(Int64 -> (Int64 -> Int64))</summary>
  public static long Cheapest(long int64_1, long int64_2)
  {
    throw new NotImplementedException("not implemented: lessons.menu::cheapest");
  }
}
