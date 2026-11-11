// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
namespace Example;

using LawSpec.Actors;
using LawSpec.Data;
using LawSpec.Generated;

public static class Restarts
{
    public static Tab OpenTab() => new(0L);

    public static Pair<long, Tab> Add(Tab tab, byte amount)
    {
        var after = tab.Total + amount;
        return new Pair<long, Tab>(after, new Tab(after));
    }

    public static Pair<long, Tab> Total(Tab tab) => new(tab.Total, tab);

    public static long KeepsTotal(byte amount)
    {
        var bar = BarSupervisor.Start(ActorHandlers.Tab);
        bar.Tab.Add(amount);
        bar.Tab.Crash();
        var total = bar.Tab.Total();
        bar.Stop();
        return total;
    }
}
