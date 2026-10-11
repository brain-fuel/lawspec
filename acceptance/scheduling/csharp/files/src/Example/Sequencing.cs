// User-owned LawSpec adapter: pause notes when it is called.
namespace Example;

public static class Sequencing
{
    public static bool Pause(int n)
    {
        ScheduleLog.Note("start", n);
        System.Threading.Thread.Sleep(5);
        ScheduleLog.Note("end", n);
        return true;
    }
}
