using System.Runtime.InteropServices.JavaScript;
using System.Runtime.Versioning;
using System.Threading.Tasks;
using Fantomas.Core;
using Microsoft.FSharp.Control;

namespace LawSpec.Learn;

[SupportedOSPlatform("browser")]
public static partial class Formatter
{
  [JSExport]
  public static async Task<string> FormatFSharp(string source)
  {
    var operation = CodeFormatter.FormatDocumentAsync(false, source);
    var result = await FSharpAsync.StartAsTask(operation, null, null);
    return result.Code;
  }
}

public class Program
{
  public static void Main()
  {}
}
