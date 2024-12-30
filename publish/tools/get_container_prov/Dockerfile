FROM alpine:3.21.3

WORKDIR /app

RUN RUN apk update && apk upgrade && apk add git

COPY run.sh .

CMD ["sh", "/app/run.sh"]
