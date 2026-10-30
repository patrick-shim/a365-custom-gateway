# A365 Gateway Console — static SPA served by nginx, proxying /api to the Gateway API.
FROM --platform=$BUILDPLATFORM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# Fluent UI's global focus manager is shared inside jsdom. Run files serially so
# image builds do not intermittently race while dialogs mount and unmount.
RUN npm run check:reachability \
    && npm run check:proxy \
    && npm test -- --reporter=dot --maxWorkers=1 --minWorkers=1 --testTimeout=15000 \
    && npm run build

FROM nginx:1.27-alpine AS final
ARG SOURCE_REVISION=unknown
LABEL org.opencontainers.image.revision=$SOURCE_REVISION
# Templated nginx config (GATEWAY_API_ORIGIN substituted at start).
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY docker-entrypoint.sh /docker-entrypoint.d/40-a365-config.sh
COPY --from=build /app/dist /usr/share/nginx/html
RUN sed -i 's/\r$//' /docker-entrypoint.d/40-a365-config.sh \
    && chmod +x /docker-entrypoint.d/40-a365-config.sh
EXPOSE 8080
