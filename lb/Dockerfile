FROM --platform=linux/amd64 alpine:latest
ARG LB=1
ENV KEEPALIVED_CONF=/etc/keepalived/lb${LB}/keepalived.conf
RUN apk add --no-cache keepalived iproute2 ipvsadm bash socat
COPY entrypoint.sh serve-router-id.sh ipvs-state.sh watch-virtual-server.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/serve-router-id.sh /usr/local/bin/ipvs-state.sh /usr/local/bin/watch-virtual-server.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# 实际 -f 由 entrypoint 根据 KEEPALIVED_CONF 补上（镜像构建时按 LB 写入）
CMD ["keepalived", "-nl"]
