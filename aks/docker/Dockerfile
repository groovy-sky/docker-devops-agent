FROM ubuntu:focal

ENV DEBIAN_FRONTEND=noninteractive
ENV TARGETARCH=linux-x64

COPY ./start.sh .

RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

RUN apt-get update && apt-get install software-properties-common && add-apt-repository "deb http://security.ubuntu.com/ubuntu xenial-security main"\
    && apt-get update &&  apt-get install -y \
    ca-certificates \
    curl \
    jq \
    git \
    iputils-ping \
    libcurl4 \
    libicu55 \
    libunwind8 \
    netcat \
    libssl1.0 \
    && curl -LsS https://aka.ms/InstallAzureCLIDeb | bash \
    && rm -rf /var/lib/apt/lists/* \
    && chmod a+x start.sh

USER nobody

ENTRYPOINT ["./start.sh"]
