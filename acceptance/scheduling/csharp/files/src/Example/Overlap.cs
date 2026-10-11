// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
namespace Example;

using System.Threading.Tasks;

public static class Overlap
{
    public static async Task<bool> Nap(int n)
    {
        ScheduleLog.Note("start", n);
        await Task.Delay(300);
        ScheduleLog.Note("end", n);
        return true;
    }
}
