FROM alpine:3.21

WORKDIR /app

RUN apk update && apk upgrade && apk add git

COPY run.sh .

CMD ["sh", "/app/run.sh"]
