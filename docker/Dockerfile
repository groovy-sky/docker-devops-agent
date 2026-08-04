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

WORKDIR /azp

COPY --chown=agent:agent docker/start.sh /azp/start.sh

RUN useradd --create-home --home-dir /home/agent --shell /bin/bash agent && \
  sed -i 's/\r$//' /azp/start.sh && \
  chmod 0755 /azp/start.sh

USER agent
ENV HOME=/home/agent

ENTRYPOINT ["/azp/start.sh"]
