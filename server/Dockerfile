FROM alpine:3.21

RUN apk add --no-cache openvpn iptables bash

COPY start.sh /

RUN chmod +x /start.sh

CMD ["/start.sh"]
