namespace Example;

using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;

/// <summary>Notes when a call starts and ends, in the file LAWSPEC_SCHEDULE_LOG names.</summary>
public static class ScheduleLog
{
    private static readonly object gate = new();

    public static void Note(string evt, int n)
    {
        var path = Environment.GetEnvironmentVariable("LAWSPEC_SCHEDULE_LOG");
        if (string.IsNullOrEmpty(path)) return;
        var millis = Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;
        lock (gate) File.AppendAllText(path, string.Format(CultureInfo.InvariantCulture, "{0} {1} {2:F3}\n", evt, n, millis));
    }
}
