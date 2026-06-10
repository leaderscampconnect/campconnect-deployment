FROM alpine/git:2.47.2 AS source
ARG SERVICE_REPOSITORY
ARG SERVICE_REF=main
ARG SERVICE_REVISION
RUN if [ -n "${SERVICE_REVISION}" ]; then \
      git init /source \
      && git -C /source remote add origin "${SERVICE_REPOSITORY}" \
      && git -C /source fetch --depth 1 origin "${SERVICE_REVISION}" \
      && git -C /source checkout --detach FETCH_HEAD; \
    else \
      git clone --depth 1 --branch "${SERVICE_REF}" "${SERVICE_REPOSITORY}" /source; \
    fi

FROM node:20-alpine
RUN apk add --no-cache curl
WORKDIR /app
COPY --from=source /source/package*.json ./
RUN npm ci --omit=dev
COPY --from=source /source/src ./src
USER node
ENTRYPOINT ["node", "src/server.js"]
