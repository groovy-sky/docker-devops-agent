FROM ubuntu:24.04

RUN apt update && \
  apt install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    file \
    git \
    jq \
    libicu74 \
    tar && \
  rm -rf /var/lib/apt/lists/*

RUN mkdir -p /azp

WORKDIR /azp

COPY docker/start.sh /azp/start.sh

RUN sed -i 's/\r$//' /azp/start.sh && \
  chmod 0755 /azp/start.sh

ENV AGENT_ALLOW_RUNASROOT=1

ENTRYPOINT ["/azp/start.sh"]
