// gradle check generates the LawSpec code before the main code compiles,
// compiles and runs the tests, then runs lawspec check and lawspec test
// (which runs gradle test). lawspec generate writes the runtime to src/main
// and the tests to src/test; the sample keeps only the adapter it owns and
// relies on the plugin's defaults. ref:DEC-jvm-native-host
plugins {
  kotlin("jvm") version "2.3.21"
  id("dev.goforge.lawspec") version "0.36.2-SNAPSHOT"
}

group = "dev.goforge.samples"

val lawspecRepository: String =
  providers.gradleProperty("lawspecRepository").orNull
    ?: "${System.getProperty("user.home")}/.m2/repository"

repositories {
  // The platform jar of the plugin's version.
  maven {
    url = uri(lawspecRepository)
    content { includeGroup("dev.goforge") }
  }
  mavenCentral()
}

kotlin { jvmToolchain(25) }

dependencies {
  implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0")
  testImplementation("io.kotest:kotest-runner-junit5:5.9.1")
  testImplementation("io.kotest:kotest-assertions-core:5.9.1")
  testImplementation("io.kotest:kotest-property:5.9.1")
}

tasks.test { useJUnitPlatform() }
