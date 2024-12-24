FROM rust:1.83-slim

WORKDIR /app

RUN cargo install zizmor
RUN apt-get update && apt-get install -y jq

COPY run.sh .

CMD ["sh", "/app/run.sh"]
