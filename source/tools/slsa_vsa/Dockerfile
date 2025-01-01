FROM alpine:3.21

RUN apk update && apk upgrade && apk add cosign && apk add jq

COPY run.sh .
COPY vsa_template.jq .

CMD [ "/run.sh" ]
