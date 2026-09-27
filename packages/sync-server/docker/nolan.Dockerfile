# Self-contained build of the sync server + web app from this checkout.
# Upstream builds the web app outside Docker (`yarn build:server` in CI) and then
# packages it with ubuntu.Dockerfile; this file does both so the host needs no
# Node toolchain. Build context: repo root.

FROM node:24-bookworm AS web

RUN apt-get update && apt-get install -y openssl

WORKDIR /app

COPY .yarn ./.yarn
COPY yarn.lock package.json .yarnrc.yml tsconfig.json lage.config.js ./
COPY bin ./bin
COPY packages ./packages

RUN yarn install

ENV NODE_OPTIONS=--max_old_space_size=6144

# lage hashes tasks with `git ls-tree HEAD`; .dockerignore drops .git, so seed one.
RUN git -c init.defaultBranch=master init -q \
    && git -c user.email=build@docker -c user.name=docker-build add -A \
    && git -c user.email=build@docker -c user.name=docker-build commit -qm build

RUN yarn build:server

FROM node:24-bookworm AS builder

WORKDIR /app

COPY .yarn ./.yarn
COPY yarn.lock package.json .yarnrc.yml ./
COPY --from=web /app/packages ./packages

RUN yarn workspaces focus @actual-app/sync-server --production

# Dereference yarn's workspace:* symlinks so the prod stage can copy just node_modules.
RUN cp -RL node_modules node_modules.real \
    && rm -rf node_modules \
    && mv node_modules.real node_modules

RUN find node_modules/@actual-app -maxdepth 2 -type d \
    \( -name src -o -name e2e -o -name __tests__ -o -name __mocks__ -o -name tests -o -name test -o -name build-stats \) \
    -exec rm -rf {} +

FROM node:24-bookworm-slim AS prod

RUN apt-get update && apt-get install -y tini && apt-get clean -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV NODE_ENV=production

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/packages/sync-server/package.json ./
COPY --from=builder /app/packages/sync-server/build ./

# Keep the legacy script path used by health checks.
RUN mkdir -p src && ln -s ../scripts src/scripts

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
EXPOSE 5006
CMD ["node", "app.js"]
