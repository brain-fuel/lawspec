// User-owned LawSpec adapter.
namespace Lessons;

using LawSpec.Data;

public static class Orders
{
    public static long Price(Drink value0) => (value0.Size.IsLarge ? 320L : 250L) + value0.Shots * 60L;
}
