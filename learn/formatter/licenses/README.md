These notices accompany the packaged on-device formatter; they do not license
learner projects.

- Fantomas.Core/Fantomas.FCS 8.1.0: Apache-2.0, including notices in the source
  [license at the NuGet repository commit](https://github.com/fsprojects/fantomas/blob/9b5cde1f5f9d944e6979726d1a2df6f3b42f5714/LICENSE.md).
- FSharp.Core 10.0.100: MIT; [F# license](https://github.com/dotnet/fsharp/blob/main/License.txt).
- .NET Mono browser runtime 10.0.12: license and third-party notices copied
  verbatim from that locked NuGet runtime package.

The build copies these files, plus the Prettier, brace-style plugin and Zod
licenses, into the static vendor artifact. No live license retrieval is needed
when building or running the course.
