FROM ubuntu:26.04

RUN apt-get update
RUN apt-get -y install jq curl bc

RUN useradd -u 65432 -m synth

USER synth
ENV HOME /home/synth
RUN mkdir -p /home/synth/conf && mkdir -p /home/synth/scripts
WORKDIR /home/synth

RUN curl -k -L https://github.com/drmille2/synthehol/releases/download/v0.2.0/synthehol-x86_64-unknown-linux-gnu.tar.gz -o synthehol.tgz && tar -xzvf synthehol.tgz
COPY scripts/* /home/synth/scripts/

VOLUME ["/home/synth/conf"]
ENTRYPOINT ["/home/synth/synthehol","--config","/home/synth/conf"]
