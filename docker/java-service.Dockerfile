FROM alpine/git:2.47.2 AS source
ARG SERVICE_REPOSITORY
ARG SERVICE_REF=main
RUN git clone --depth 1 --branch "${SERVICE_REF}" "${SERVICE_REPOSITORY}" /source

FROM maven:3.9.9-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY --from=source /source/ ./
RUN if [ -x ./mvnw ]; then \
      ./mvnw -q -DskipTests package; \
    else \
      mvn -q -DskipTests package; \
    fi \
    && find target -maxdepth 1 -name "*.jar" ! -name "*.original" -print -quit \
      | xargs -I{} cp "{}" /app.jar

FROM eclipse-temurin:17-jre-jammy
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 appuser
WORKDIR /app
COPY --from=build /app.jar app.jar
USER appuser
ENTRYPOINT ["java", "-jar", "app.jar"]
