// The LawSpec Gradle plugin, dev.goforge.lawspec: tasks for every lawspec
// command over the natively compiled lawspec, which the plugin resolves as
// dev.goforge:lawspec-<platform> and runs through the dev.goforge:lawspec
// launcher. Written in Java; configuration-cache safe.
// ref:DEC-jvm-native-host ref:DEC-maven-central-coordinates
plugins {
  `java-gradle-plugin`
  signing
  id("com.gradle.plugin-publish") version "1.3.1"
}

// The launcher of this version. A local build takes dev.goforge from the
// Maven repository -PlawspecRepository names (hosts/jvm installs there), or
// else from the local Maven repository.
val lawspecRepository: Provider<String> = providers.gradleProperty("lawspecRepository")
val repositoryPath: String =
  lawspecRepository.orNull ?: "${System.getProperty("user.home")}/.m2/repository"

repositories {
  maven {
    name = "lawspecLocal"
    url = uri(repositoryPath)
    content { includeGroup("dev.goforge") }
  }
  mavenCentral()
}

val functionalTest: SourceSet by sourceSets.creating

dependencies {
  implementation("dev.goforge:lawspec:${project.version}")
  // Reads lawspec describe --json, for the generated directories.
  implementation("com.google.code.gson:gson:2.13.2")
  "functionalTestImplementation"("org.junit.jupiter:junit-jupiter:5.12.2")
  "functionalTestRuntimeOnly"("org.junit.platform:junit-platform-launcher:1.12.2")
}

tasks.withType<JavaCompile>().configureEach {
  options.release = 17
  options.encoding = "UTF-8"
}

tasks.processResources {
  val version = project.version.toString()
  inputs.property("version", version)
  filesMatching("**/plugin.properties") { expand("version" to version) }
}

gradlePlugin {
  website = "https://github.com/brain-fuel/lawspec"
  vcsUrl = "https://github.com/brain-fuel/lawspec"
  plugins {
    create("lawspec") {
      id = "dev.goforge.lawspec"
      implementationClass = "dev.goforge.lawspec.gradle.LawSpecPlugin"
      displayName = "LawSpec"
      description =
        "Runs LawSpec's check, generate, test, prove and every other command from Gradle."
      tags = listOf("lawspec", "specification", "laws", "testing", "code-generation")
    }
  }
  testSourceSets(functionalTest)
}

// TestKit builds in build/testkit, with their own Gradle user home, so
// their daemons and caches are this build's; they resolve the platform jar
// from the same repository as the launcher.
val functionalTestTask =
  tasks.register<Test>("functionalTest") {
    description = "Runs the TestKit functional tests."
    group = "verification"
    testClassesDirs = functionalTest.output.classesDirs
    classpath = functionalTest.runtimeClasspath
    useJUnitPlatform()
    systemProperty("lawspec.repository", repositoryPath)
    systemProperty("lawspec.testkit", layout.buildDirectory.dir("testkit").get().asFile.path)
    testLogging { events("passed", "failed", "skipped") }
  }

tasks.check { dependsOn(functionalTestTask) }

// A release (-Prelease) signs with the gpg command; the owner publishes with
// publishPlugins. Nothing here publishes on its own.
val releasing: Boolean = providers.gradleProperty("release").isPresent

signing {
  isRequired = releasing
  useGpgCmd()
}

if (!releasing) {
  tasks.withType<Sign>().configureEach { enabled = false }
}

// A local build publishes the plugin and its marker to the same repository,
// for builds that apply it by id: publishAllPublicationsToLawspecLocalRepository.
publishing {
  repositories {
    maven {
      name = "lawspecLocal"
      url = uri(repositoryPath)
    }
  }
}
