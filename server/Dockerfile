FROM oven/bun:1-slim
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production
COPY src ./src
ENV NODE_ENV=production PORT=8080
EXPOSE 8080
CMD ["bun", "src/index.ts"]
