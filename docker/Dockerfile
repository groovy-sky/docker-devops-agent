FROM ubuntu:focal

ENV DEBIAN_FRONTEND=noninteractive
RUN echo "APT::Get::Assume-Yes \"true\";" > /etc/apt/apt.conf.d/90assumeyes

RUN apt-get update && apt-get install software-properties-common

RUN add-apt-repository "deb http://security.ubuntu.com/ubuntu xenial-security main" \
&& apt-get update \
&& apt-get install -y \
        ca-certificates \
        curl \
        jq \
        git \
        iputils-ping \
        libcurl4 \
        libicu55 \
        libunwind8 \
        netcat

WORKDIR /azp

COPY ./docker/start.sh .
RUN chmod +x start.sh

CMD ["./start.sh"]
