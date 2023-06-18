import org.gradle.api.JavaVersion.VERSION_11

group = "com.github.mbto.maxmind-geoip2-csv2sql-converter"
version = "1.1"

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

    val jUnitVer = "5.9.3"
    testCompile("org.junit.jupiter:junit-jupiter-engine:$jUnitVer")
    testCompile("org.junit.jupiter:junit-jupiter-params:$jUnitVer")
    testCompile("org.junit.vintage:junit-vintage-engine:$jUnitVer")
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