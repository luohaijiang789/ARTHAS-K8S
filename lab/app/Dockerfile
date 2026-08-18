# syntax=docker/dockerfile:1
# Arthas-K8s 测试靶机镜像：一个 build stage + 三个运行时 target
#   docker build --target normal    -t arthas-lab/normal:17    .   # JDK+shell+root → 路径 A
#   docker build --target distroless -t arthas-lab/distroless:17 .  # 无 shell → 路径 C
#   docker build --target jre       -t arthas-lab/jre:17       .   # JRE-only → 路径 C 传 JDK
# app-readonly 复用 arthas-lab/normal:17（readOnlyRootFS 是 pod spec 属性，非镜像属性）

# ---- build：maven 打 jar（自包含，不依赖宿主 mvn/jdk）----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package -DskipTests

# ---- normal：JDK + shell + root + 可写 rootFS ----
FROM eclipse-temurin:17-jdk AS normal
COPY --from=build /build/target/arthas-lab-app.jar /app/app.jar
EXPOSE 8080
CMD ["java", "-jar", "/app/app.jar"]

# ---- distroless：无 shell → probe 判定 ephemeral-container ----
FROM gcr.io/distroless/java17-debian12 AS distroless
COPY --from=build /build/target/arthas-lab-app.jar /app/app.jar
EXPOSE 8080
# distroless/java17 entrypoint 已是 java，CMD 只给参数
CMD ["-jar", "/app/app.jar"]

# ---- jre：JRE-only，无 jcmd/tools.jar → probe 判定 ephemeral(传 JDK) ----
FROM eclipse-temurin:17-jre AS jre
COPY --from=build /build/target/arthas-lab-app.jar /app/app.jar
EXPOSE 8080
CMD ["java", "-jar", "/app/app.jar"]
