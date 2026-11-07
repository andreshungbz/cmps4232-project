# ====================================================================================
# Dockerfile - Build the Systems Administration health dashboard.
# Build from phase-03/docker: sudo docker build -t health-dashboard:1.0 .
# Persistent reports are mounted into the metrics directory during deployment.
# ====================================================================================

# ====================================================================================
# BASE IMAGE
# ====================================================================================

# Use an explicit NGINX version with a small Alpine Linux base.
FROM nginx:1.30.6-alpine

LABEL org.opencontainers.image.title="Systems Administration Health Dashboard" \
      org.opencontainers.image.description="NGINX dashboard serving host-generated network reports."

# ====================================================================================
# CONFIGURATION
# ====================================================================================

# Default internal listening port; the NGINX template consumes this variable.
# Restrict template substitution to this variable to preserve NGINX variables.
ENV NGINX_PORT=80 \
    NGINX_ENVSUBST_FILTER="^NGINX_PORT$"

# The inherited entrypoint renders this template when the container starts.
COPY --chmod=0644 nginx/default.conf.template /etc/nginx/templates/default.conf.template

# ====================================================================================
# DASHBOARD CONTENT
# ====================================================================================

COPY --chmod=0644 html/index.html /usr/share/nginx/html/index.html

# Prepare the mount destination. Host reports are supplied at deployment time.
RUN mkdir -p /usr/share/nginx/html/metrics \
    && chmod 0755 /usr/share/nginx/html/metrics

# ====================================================================================
# SERVICE STARTUP
# ====================================================================================

# Document the default container port. Host port publishing is configured separately.
EXPOSE 80

# Keep NGINX in the foreground so Docker can manage the service lifecycle.
# Preserve the base image's entrypoint, which processes the configuration template.
CMD ["nginx", "-g", "daemon off;"]
