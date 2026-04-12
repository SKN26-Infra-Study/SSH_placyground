FROM alpine:3.23

RUN apk add --no-cache openssh bash python3 py3-pip

RUN adduser -D -s /bin/bash user && \
    passwd -u user

RUN pip3 install --no-cache-dir --break-system-packages \
    jupyter_server \
    notebook  \
    ipykernel

COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

EXPOSE 2222
ENTRYPOINT [ "/entrypoint.sh" ]