FROM --platform=linux/amd64 alpine:latest

RUN apk add --no-cache keepalived iproute2 ipvsadm socat kmod procps

RUN mkdir -p /opt/lvs-router/bin /opt/lvs-router/keepalived /opt/lvs-router/run /opt/lvs-router/logs

COPY docker/entrypoint.sh /opt/lvs-router/bin/container-entrypoint.sh
COPY docker/serve-router-id.sh /opt/lvs-router/bin/serve-router-id.sh
COPY docker/scripts/ /opt/lvs-router/bin/
COPY docker/volumes/config/keepalived/ /opt/lvs-router/keepalived/

RUN chmod +x /opt/lvs-router/bin/*.sh

ENTRYPOINT ["/opt/lvs-router/bin/container-entrypoint.sh"]
