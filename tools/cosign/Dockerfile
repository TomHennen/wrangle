FROM alpine:3.21

RUN apk update && apk upgrade && apk add cosign

ENTRYPOINT [ "/usr/bin/cosign" ]
