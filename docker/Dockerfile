FROM ubuntu:24.04

RUN apt update && \
  apt upgrade -y && \
  apt install -y --no-install-recommends \
    bash curl git jq libicu74 file ca-certificates && \
  rm -rf /var/lib/apt/lists/*

# Install Azure CLI
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

WORKDIR /azp

COPY ./start.sh /azp/start.sh
RUN sed -i 's/\r$//' /azp/start.sh && chmod 755 /azp/start.sh

# Create agent user and set up home directory
RUN useradd -m -d /home/agent agent && \
  chown -R agent:agent /azp /home/agent

USER agent
ENV AGENT_ALLOW_RUNASROOT=true

ENTRYPOINT ["/usr/bin/env", "bash", "/azp/start.sh"]
