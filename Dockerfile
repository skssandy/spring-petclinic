# ── Stage 1: Build ────────────────────────────────────────────────────────
# Uses full JDK + Maven to compile and package the JAR
FROM maven:3.9-eclipse-temurin-17 AS builder

WORKDIR /app

# Copy pom.xml first — Docker caches this layer
# Maven dependencies only re-download when pom.xml changes
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source and build the JAR
COPY src ./src
RUN mvn clean package -DskipTests -B

# ── Stage 2: Runtime ──────────────────────────────────────────────────────
# Slim JRE-only image — no compiler, no Maven, no source code
# Cuts final image from ~600MB to ~150MB
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# Non-root user — security best practice
RUN addgroup -S petclinic && adduser -S petclinic -G petclinic

# Copy only the built JAR from builder stage
COPY --from=builder /app/target/*.jar app.jar
RUN chown petclinic:petclinic app.jar

USER petclinic

# Spring Boot runs on 8080 by default
EXPOSE 8080

# JVM flags:
# -XX:+UseContainerSupport  — respect Docker/K8s memory limits (not host RAM)
# -XX:MaxRAMPercentage=75.0 — use max 75% of container memory limit for heap
ENTRYPOINT ["java", \
            "-XX:+UseContainerSupport", \
            "-XX:MaxRAMPercentage=75.0", \
            "-jar", "app.jar"]
