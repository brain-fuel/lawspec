---
id: lawspec.how-to.install-gradle
kind: how-to
title: Install the Gradle plugin
---
# Install the Gradle plugin

The `dev.goforge.lawspec` plugin runs LawSpec's natively compiled `lawspec`
from Gradle, through the same launcher as [the Maven packages](install-maven.md),
with the same output. It is written in Java and is safe with the configuration
cache. ref:DEC-jvm-native-host

The plugin is on Maven Central, as `dev.goforge:lawspec-gradle-plugin` with
its plugin marker. Let Gradle resolve plugins from Maven Central, in
`settings.gradle.kts`:

```kotlin
pluginManagement {
  repositories {
    mavenCentral()
    gradlePluginPortal() // for any other plugins the build applies
  }
}
```

Then apply it by id in `build.gradle.kts`:

```kotlin
plugins {
  java
  id("dev.goforge.lawspec") version "0.36.2"
}

repositories {
  mavenCentral() // dev.goforge:lawspec-<platform>, the binary for this platform
}
```

The plugin resolves this platform's `dev.goforge:lawspec-<platform>` jar of
its own version from the project's repositories.

## Tasks

Every command is a task: `lawspecCheck`, `lawspecGenerate`, `lawspecTest`,
`lawspecProve`, `lawspecExplain`, `lawspecDoctor`, `lawspecFmt`,
`lawspecMutate`, `lawspecPackage`, `lawspecEvidence`, `lawspecAdvise`,
`lawspecInspect`, `lawspecPrelude`, `lawspecDescribe`, `lawspecFetch`,
`lawspecUpdate`, `lawspecExamples`, `lawspecInit`, `lawspecProjectStatus`,
`lawspecProjectValidate` and `lawspecLearn` (which also resolves
`dev.goforge:lawspec-resources`). `gradle tasks --group lawspec` lists them.

- `lawspecGenerate` runs before main compilation: `compileJava`, and
  `compileKotlin`, `compileGroovy` or `compileScala` when those plugins are
  applied. Test compilation follows main compilation.
- The directories `lawspecGenerate` writes into join the source sets, as
  `lawspec describe --json` reports the targets: a target's
  `:generated-source-dir` in the main Java sources, and its
  `:generated-test-dir` in the test Java sources and, without the `.java`
  files, in `processTestResources`. A target without them (Kotlin, Groovy,
  Scala) generates into `src/main` and `src/test`, which the source sets
  already hold. Only the targets whose `:root` is the project's directory
  count, and only the one `target` names when it is set; Gradle runs
  `lawspec describe` only when a build compiles.
- `check` runs `lawspecCheck` and `lawspecTest`; `lawspecTest` runs after the
  build's own `test`.

A task that exits with a code other than 0 fails the build. lawspec keeps its
own record of what it checked, generated and tested, so the tasks always run.

## Configure

```kotlin
lawspec {
  config = file("lawspec.edn")      // --config; lawspec finds lawspec.edn without it
  target = "kotlin"                 // --target
  arguments.add("--timings")        // appended to every task's command
  environment.put("LAWSPEC_X", "y")
  generateBeforeMainCompile = true  // the wirings, each on by default
  addSourceRoots = true
  checkOnCheck = true
  testOnCheck = true
}

tasks.lawspecTest { arguments.addAll("--seed", "7") }
```

On the command line: `gradle lawspecExplain --lawspec-args=--view
--lawspec-args=math`.

`hosts/jvm/samples/gradle-kotlin` uses the defaults: its generated runtime
is main code under `src/main`, which is not committed. A Java target's
`lawspec test` and `lawspec generate` run Maven, so a Java target needs a
`pom.xml`; Kotlin and Groovy targets use Gradle. lawspec generate's own Gradle
inspection does not support the configuration cache yet, so leave
`org.gradle.configuration-cache` off in a project whose targets lawspec
generates through Gradle.

## Build from a checkout

After [installing the Maven packages](install-maven.md#build-and-install-from-a-checkout)
into the local Maven repository:

```sh
cd hosts/jvm/gradle-plugin
gradle publishToMavenLocal
```

Then add `mavenLocal()` to `pluginManagement { repositories { } }` in
`settings.gradle.kts` and to the project's repositories. `bash tools/hosts.sh
jvm-gradle` builds the plugin with its TestKit tests and runs the sample,
using `.artifacts/jvm/repository`.

## Publish a release (owner)

The plugin goes to Maven Central with the Maven packages, in the same
`ax publish` bundle ([Install from Maven](install-maven.md#publish-a-release-owner)).
After the Maven staging build, from the same checkout:

```sh
cd hosts/jvm/gradle-plugin
gradle -Pversion=0.36.2 -PlawspecRepository=$PWD/../target/central-staging \
  publishAllPublicationsToCentralStagingRepository
```

`-PlawspecRepository` points the build at the staged Maven packages; without
it Gradle looks for `dev.goforge:lawspec` at the release version in the local
Maven repository, where it is not installed.

It writes the plugin jar, its sources and javadoc jars, its Gradle module
metadata and the plugin marker `dev.goforge.lawspec:dev.goforge.lawspec.gradle.plugin`,
unsigned, into `hosts/jvm/target/central-staging`. Nothing in the Gradle build
signs or uploads. ref:DEC-maven-central-coordinates
