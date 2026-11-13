---
id: lawspec.how-to.spring-boot
kind: how-to
title: Add LawSpec to a Spring Boot service
---
# Add LawSpec to a Spring Boot service

This guide adds a Java target to an existing Spring Boot application that is
built with Maven. The application's own build does not change. The laws live in
a second Maven project beside it, which depends on the application's classes,
compiles at the application's Java release and keeps generated code under
`target/`.

The examples use a service in `service/` with the coordinates
`com.example:shop:1.4.0`, on Spring Boot 4.0.9 and Java 21. Replace them with
yours.

## Use a separate target root

Give the laws their own project root, `service-laws/`, rather than generating
into the application:

- Generated runtime and tests stay out of the application's artifact.
- `doctor` requires things of the build that tests run in: an unfiltered
  Surefire, a fixed compiler release and no toolchain overrides. It asks them
  of `service-laws/pom.xml` only.
- The adapters call the application as any other client would, through its
  jar.

```text
lawspec.edn
laws/                      specifications
service/                   the Spring Boot application, unchanged
service-laws/
  pom.xml                  yours
  src/main/java/           your adapters
  src/test/java/           your generator factories, if any
  target/generated-sources/lawspec/        generated
  target/generated-test-sources/lawspec/   generated
```

## Install the application's plain jar

`spring-boot-maven-plugin` repackages the application's jar into an executable
archive with the classes under `BOOT-INF/classes`. Another project cannot
compile against that. Skip repackaging when you install the application for
the laws:

```sh
mvn -f service/pom.xml install -Dspring-boot.repackage.skip=true
```

The installed `shop-1.4.0.jar` is then the ordinary jar of classes. If the
application already gives its executable archive a classifier
(`<classifier>exec</classifier>` on the `repackage` goal), the plain jar is
its main artifact and the property is unnecessary.

## Declare the target

Run `init` for the new root. It writes the target into `lawspec.edn`, creates a
starting `pom.xml` at release 21, and prints the build registration that the
generated directories need:

```sh
npx lawspec init --target java --project service-laws --no-install \
  --release 21 \
  --generated-source-dir target/generated-sources/lawspec \
  --generated-test-dir target/generated-test-sources/lawspec
```

The target in `lawspec.edn`:

```edn
{
  :language :java
  :root "service-laws"
  :release 21
  :generated-source-dir "target/generated-sources/lawspec"
  :generated-test-dir "target/generated-test-sources/lawspec"
}
```

`:release 21` is for a service on Java 21; leave it out on Java 25. The
generated code is the same at both. A program that imports `lawspec.crypto` or
`lawspec.network` needs Java 24 or later, and generation says so; see
[Java release 21](../reference/compatibility.md#java-release-21).

## Write the POM

Replace the `pom.xml` that `init` created with one that knows the application:

```text
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>shop-laws</artifactId>
  <version>1.4.0</version>
  <properties>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-dependencies</artifactId>
        <version>4.0.9</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>shop</artifactId>
      <version>1.4.0</version>
    </dependency>
    <dependency>
      <groupId>org.jetbrains</groupId>
      <artifactId>jetCheck</artifactId>
      <version>0.3.0</version>
      <scope>test</scope>
    </dependency>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.14.1</version>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.4</version>
      </plugin>
      <!-- The build-helper-maven-plugin block that init printed goes here. -->
    </plugins>
  </build>
</project>
```

### Import the application's BOMs

The application's parent, `spring-boot-starter-parent`, manages the version of
every library the application uses. That management does not travel with the
jar: in `service-laws`, Maven resolves the application's transitive
dependencies by this project's own rules. Without the same management it can
choose other versions than the application runs on. The tests can then fail
with `NoClassDefFoundError` for classes the application expects, for example
when older Jackson 2 artifacts are resolved beside the Jackson 3 that Spring
Boot 4 uses. A small application may resolve the same versions either way;
import the BOMs regardless, so that it stays so as dependencies are added.

Import, in `dependencyManagement`, every BOM the application's build imports,
at the same versions: `spring-boot-dependencies` at the application's Spring
Boot version, then any others, such as Spring Cloud's. `service-laws` does not
need `spring-boot-starter-parent` as its parent, and is simpler to check
without it.

### Let one BOM decide JUnit

A BOM also manages JUnit, whatever version a dependency declares. Declaring
`junit-jupiter` 5.14.0 under Spring Boot 4's BOM resolves the 5.14.0 aggregate
with the 6.0.3 API and engine beneath it. So leave the version off
`junit-jupiter`, as above, and let dependency management choose all of it.

LawSpec supports JUnit Jupiter 5.14.x and 6.0.x. Spring Boot 4.0 and 4.1 manage
6.0.x, so the POM above needs nothing more. A BOM that manages a release outside
that range needs JUnit's own BOM imported before it, because Maven keeps the
first management it reads. Spring Boot 3.5 manages JUnit 5.12, for example:

```text
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>org.junit</groupId>
      <artifactId>junit-bom</artifactId>
      <version>5.14.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-dependencies</artifactId>
      <version>3.5.16</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

`doctor` reads the versions Maven resolved, from `mvn dependency:tree`, and
names the resolved `junit-jupiter-api` when it is outside the supported range.

### Register the generated directories

Maven compiles one source root unless told of more. Paste the
`build-helper-maven-plugin` block that `init` printed into `build/plugins`. It
adds `target/generated-sources/lawspec` as a source root and
`target/generated-test-sources/lawspec` as a test source root, and reads the
second as a test resource root as well, for the JUnit configuration a
[harness](../reference/language/harness.md) generates. The same `init` command
prints the block again at any time; it never edits `pom.xml`.

## Generate and test

```sh
npx lawspec doctor
npx lawspec generate
npx lawspec test
```

`generate` writes the generated files under `service-laws/target/` and one
adapter stub per unit under `service-laws/src/main/java`. The stubs are yours:
make each method call the application.

```java
package example;

public final class Discounts
{
  public static int discount(lawspec.data.Order order)
  {
    return com.example.shop.DiscountPolicy.discount(order.items(), order.total());
  }
}
```

Commit `lawspec.edn`, `laws/`, `service-laws/pom.xml` and the adapters.
`service-laws/target/` stays ignored, as in any Maven project.
`service-laws/.lawspec/generated.json` records the hash of each generated
file; commit it or ignore it.

`mvn clean` deletes the generated directories with the rest of `target/`, and
a clean checkout has none. `lawspec generate` writes them again, byte for byte,
and leaves the adapters alone. In CI, generate before Maven compiles:

```sh
mvn -f service/pom.xml install -Dspring-boot.repackage.skip=true
npx lawspec generate
npx lawspec test
```

`lawspec test` runs `mvn test` in `service-laws` and refuses to run when the
generated files are missing or out of date, so `generate` comes first. Do not
use `lawspec generate --check` here: it fails whenever a generated file is
missing, which is always so in a clean checkout. See
[generated directories](../explanation/ownership-and-regeneration.md#generated-directories).

## Map records to classes you already generate

By default each LawSpec record becomes a generated Java record under
`lawspec.data`, and an adapter converts between it and the application's own
class. When the application already has that class, for example one generated
from an Avro schema, a [native binding](bind-native-types.md) maps the record
to it instead. The generated code then uses your class directly, and an
adapter method is a one-line delegation.

A Java binding names the class, which the bridge constructs with the fields in
LawSpec declaration order, and an accessor method for each field:

```edn
{
  :type "example.offers::type::Offer"
  :native ["com" "example" "shop" "avro" "Offer"]
  :constructors [
    {
      :constructor "Offer"
      :native ["com" "example" "shop" "avro" "Offer"]
      :style "record"
      :fields [
        {
          :field "offerCode"
          :native "getOfferCode"
        }
        {
          :field "quantity"
          :native "getQuantity"
        }
      ]
    }
  ]
}
```

Declare the LawSpec record's fields in the order of the class's
all-arguments constructor. A class that does not fit, because it is built only
through a builder or holds text as `CharSequence`, needs a
[codec hook](custom-codecs-and-generators.md#convert-with-codec-hooks).
`lawspec inspect --target java` reports how the bindings resolve before you
generate. LawSpec's own tests bind hand-written Java classes; they do not
include a class generated by Avro.

Generating the contract's validators, listeners and schemas from one
declaration is not part of this; it is planned separately.
