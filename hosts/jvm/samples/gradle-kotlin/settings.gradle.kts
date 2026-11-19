// A Kotlin target built by Gradle with the LawSpec Gradle plugin; see
// docs/how-to/install-gradle.md. The plugin and its platform jar come from
// the Maven repository -PlawspecRepository names (hosts/jvm and its Gradle
// plugin publish there), or else from the local Maven repository.
// ref:DEC-jvm-native-host
pluginManagement {
  val lawspecRepository: String =
    providers.gradleProperty("lawspecRepository").orNull
      ?: "${System.getProperty("user.home")}/.m2/repository"
  repositories {
    maven {
      url = uri(lawspecRepository)
      content { includeGroup("dev.goforge") }
      content { includeGroup("dev.goforge.lawspec") }
    }
    gradlePluginPortal()
  }
}

rootProject.name = "gradle-kotlin"
