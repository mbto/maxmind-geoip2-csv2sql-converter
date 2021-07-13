import org.gradle.api.JavaVersion.VERSION_11

group = "com.github.mbto.maxmind-geoip2-csv2sql-converter"
version = "1.0"

plugins {
    java
    application
}

repositories {
    jcenter()
}

tasks {
    compileJava { options.encoding = "UTF-8" }
    compileTestJava { options.encoding = "UTF-8" }
    jar {
        exclude("*.ini", "emoji.txt")
    }
    test {
        if(!project.hasProperty("ManualTestEnabled")) {
            exclude("**/ManualTest.class")
        }
        maxParallelForks = Runtime.getRuntime().availableProcessors()
    }
}

dependencies {
    compile("com.beust:jcommander:1.78")
    compile("com.github.jgonian:commons-ip-math:1.32")
    compile("org.apache.commons:commons-compress:1.20")

    val lombokVer = "1.18.12"
    compileOnly("org.projectlombok:lombok:$lombokVer")
    annotationProcessor("org.projectlombok:lombok:$lombokVer")
    testCompile("org.projectlombok:lombok:$lombokVer")
    testAnnotationProcessor("org.projectlombok:lombok:$lombokVer")

    testCompile("junit:junit:4.13.2")
}

application {
    mainClassName = "com.github.mbto.maxmind.geoip2.csv2sql.Application"

    configure<JavaPluginConvention> {
        sourceCompatibility = VERSION_11
    }

    applicationDistribution.from("src/main/resources/") {
        into("bin")
    }
}