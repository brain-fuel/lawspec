/// Notes when a call starts and ends, in the file LAWSPEC_SCHEDULE_LOG names.
module Example.ScheduleLog

open System
open System.Diagnostics
open System.Globalization
open System.IO

let private gate = obj ()

let note (event: string) (n: int) =
    match Environment.GetEnvironmentVariable "LAWSPEC_SCHEDULE_LOG" with
    | null | "" -> ()
    | path ->
        let millis = float (Stopwatch.GetTimestamp()) * 1000.0 / float Stopwatch.Frequency
        lock gate (fun () ->
            File.AppendAllText(path, String.Format(CultureInfo.InvariantCulture, "{0} {1} {2:F3}\n", event, n, millis)))
