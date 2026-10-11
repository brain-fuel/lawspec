// User-owned LawSpec adapter: a page-view counter with one replica per thread.
namespace Example;

using System;
using System.Collections.Generic;
using System.Linq;
using LawSpec.Data;

public static class Consistency
{
    private static readonly object gate = new();
    private static readonly Dictionary<int, Dictionary<int, long>> replicas = new();
    private static int ids;

    public static Views NewViews()
    {
        lock (gate)
        {
            var id = ids++;
            replicas[id] = new Dictionary<int, long>();
            return new Views(id);
        }
    }

    public static long Hit(Views views)
    {
        lock (gate)
        {
            var mine = replicas[views.Id];
            var me = Environment.CurrentManagedThreadId;
            var count = mine.GetValueOrDefault(me) + 1;
            mine[me] = count;
            return count;
        }
    }

    public static long Total(Views views)
    {
        lock (gate) return replicas[views.Id].Values.Sum();
    }
}
