FROM alpine:3.23

RUN apk add --no-cache openssh bash vim

RUN adduser -D -s /bin/bash jump && \
    passwd -u jump

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT [ "/entrypoint.sh" ]