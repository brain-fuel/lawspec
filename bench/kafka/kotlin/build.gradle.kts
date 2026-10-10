plugins {
    kotlin("jvm") version "2.3.21"
}

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(25)
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0")
    testImplementation("io.kotest:kotest-runner-junit5:5.9.1")
    testImplementation("io.kotest:kotest-assertions-core:5.9.1")
    testImplementation("io.kotest:kotest-property:5.9.1")
}

tasks.test {
    useJUnitPlatform()
}

// The benchmark driver runs on the main classpath, printed for the harness.
tasks.register("benchClasspath") {
    dependsOn("classes")
    doLast {
        println(sourceSets["main"].runtimeClasspath.asPath)
    }
}
