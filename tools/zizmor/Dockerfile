FROM rust:1.83-slim

WORKDIR /app

COPY run.sh .

RUN cargo install zizmor

CMD ["sh", "/app/run.sh"]
