FROM alpine:latest

RUN apk update && apk add --no-cache docker-cli docker-cli-buildx

WORKDIR /app

COPY run.sh .

ENTRYPOINT ["sh", "/app/run.sh"]
