FROM alpine/git:2.47.2 AS source
ARG SERVICE_REPOSITORY
ARG SERVICE_REF=main
RUN git clone --depth 1 --branch "${SERVICE_REF}" "${SERVICE_REPOSITORY}" /source

FROM node:22-alpine AS build
WORKDIR /workspace
COPY --from=source /source/package.json /source/package-lock.json ./
RUN npm ci
COPY --from=source /source/ ./
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=source /source/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /workspace/dist/campconnect-front/browser /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=15s --timeout=3s --retries=5 \
  CMD wget -qO- http://localhost/ >/dev/null || exit 1
