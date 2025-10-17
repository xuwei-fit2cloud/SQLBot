# Build sqlbot
FROM ghcr.io/1panel-dev/maxkb-vector-model:v1.0.1 AS vector-model
FROM registry.cn-qingdao.aliyuncs.com/dataease/sqlbot-base:latest AS sqlbot-builder-frontend

# Set build environment variables
ENV SQLBOT_HOME=/opt/sqlbot
ENV UI_HOME=${SQLBOT_HOME}/frontend
ENV DEBIAN_FRONTEND=noninteractive

COPY frontend /tmp/frontend

# Create necessary directories
RUN ls -al /tmp/frontend/dist; if [ -d "/tmp/frontend/dist" ]; then mkdir -p ${UI_HOME}/dist && mv /tmp/frontend/dist ${UI_HOME}/dist && exit 0; fi && mkdir -p ${UI_HOME}

RUN cd /tmp/frontend; npm install; npm run build; mv dist ${UI_HOME}/dist

FROM registry.cn-qingdao.aliyuncs.com/dataease/sqlbot-base:latest AS sqlbot-builder-backend

# Set build environment variables
ENV PYTHONUNBUFFERED=1
ENV SQLBOT_HOME=/opt/sqlbot
ENV APP_HOME=${SQLBOT_HOME}/app
ENV PYTHONPATH=${SQLBOT_HOME}/app
ENV PATH="${APP_HOME}/.venv/bin:$PATH"
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
ENV DEBIAN_FRONTEND=noninteractive

# Create necessary directories
RUN mkdir -p ${APP_HOME}

WORKDIR ${APP_HOME}

# Install dependencies
RUN test -f "./uv.lock" && \
    --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=backend/uv.lock,target=uv.lock \
    --mount=type=bind,source=backend/pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project || echo "uv.lock file not found, skipping intermediate-layers"

COPY ./backend ${APP_HOME}

# Final sync to ensure all dependencies are installed
RUN --mount=type=cache,target=/root/.cache/uv \
   uv sync --extra cpu

# Build g2-ssr
FROM registry.cn-qingdao.aliyuncs.com/dataease/sqlbot-base:latest AS ssr-builder

WORKDIR /app

COPY g2-ssr/* /app

RUN ls -al /app; if [ -d "/app/node_modules" ]; then exit 0; fi && npm install

# Runtime stage
FROM registry.cn-qingdao.aliyuncs.com/dataease/sqlbot-python-pg:latest

RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

# Set runtime environment variables
ENV PYTHONUNBUFFERED=1
ENV SQLBOT_HOME=/opt/sqlbot
ENV PYTHONPATH=${SQLBOT_HOME}/app
ENV PATH="${SQLBOT_HOME}/app/.venv/bin:$PATH"

ENV POSTGRES_DB=sqlbot
ENV POSTGRES_USER=root
ENV POSTGRES_PASSWORD=Password123@pg

# Copy necessary files from builder
COPY start.sh /opt/sqlbot/app/start.sh
COPY g2-ssr/*.ttf /usr/share/fonts/truetype/liberation/
COPY --from=sqlbot-builder-frontend ${SQLBOT_HOME} ${SQLBOT_HOME}
COPY --from=sqlbot-builder-backend ${SQLBOT_HOME} ${SQLBOT_HOME}
COPY --from=ssr-builder /app /opt/sqlbot/g2-ssr
COPY --from=vector-model /opt/maxkb/app/model /opt/sqlbot/models

WORKDIR ${SQLBOT_HOME}/app

RUN mkdir -p /opt/sqlbot/images /opt/sqlbot/g2-ssr

EXPOSE 3000 8000 8001 5432

# Add health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000 || exit 1

ENTRYPOINT ["sh", "start.sh"]
