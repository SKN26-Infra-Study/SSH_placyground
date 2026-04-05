FROM alpine:3.23

RUN apk add --no-cache openssh bash vim

# Root user 접근을 제한하기 위한 user 생성
RUN adduser -D -s /bin/bash jump && \
    passwd -u jump

# SSH Key Copy 설정
COPY sshd_config /etc/ssh/sshd_config 

# entrypoint copy 및 실행 권한 부여
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# port 설정
EXPOSE 22
ENTRYPOINT [ "/entrypoint.sh" ]