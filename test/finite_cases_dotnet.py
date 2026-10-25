"""Black-box shared .NET cover conformance, over the actual F# runtime.

ref:DEC-planned-generation
"""

from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="lawspec-finite-dotnet-") as directory:
    project = Path(directory)
    shutil.copytree(
        root / "runtime/dotnet",
        project / "runtime",
        ignore=shutil.ignore_patterns("bin", "obj"),
    )
    shutil.copyfile(root / "test/locks/dotnet-sdk.json", project / "global.json")
    shutil.copyfile(root / "test/FiniteCases.fs", project / "FiniteCases.fs")
    (project / "FiniteCases.fsproj").write_text("""<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework><OutputType>Exe</OutputType><TreatWarningsAsErrors>true</TreatWarningsAsErrors></PropertyGroup>
  <ItemGroup><Compile Include="FiniteCases.fs" /><ProjectReference Include="runtime/LawSpec.Testing/LawSpec.Testing.fsproj" /></ItemGroup>
</Project>
""")
    subprocess.run(
        ["dotnet", "run", "--project", "FiniteCases.fsproj", "--verbosity", "quiet"],
        cwd=project,
        check=True,
    )
