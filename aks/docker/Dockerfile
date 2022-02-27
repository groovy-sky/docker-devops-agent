FROM ubuntu:focal

ENV DEBIAN_FRONTEND=noninteractive
ENV TARGETARCH=linux-x64

ENV AZP_PATH=/tmp/azp
ENV AZP_TOKEN_FILE=$AZP_PATH/.token

WORKDIR $AZP_PATH

COPY ./start.sh .

RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes && chmod -R g+wX $AZP_PATH && chown nobody:nogroup -R $AZP_PATH

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