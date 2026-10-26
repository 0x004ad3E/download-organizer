FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    jq \
    util-linux \
    curl \
    coreutils \
    findutils

WORKDIR /app

COPY organize-downloads.sh /app/organize-downloads.sh

RUN chmod 755 /app/organize-downloads.sh

CMD ["/bin/bash", "/app/organize-downloads.sh"]
